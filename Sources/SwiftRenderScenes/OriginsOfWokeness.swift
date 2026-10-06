import SwiftUI
import SwiftRender

/// OriginsOfWokeness — an attributed visual summary of Paul Graham's January
/// 2025 essay "The Origins of Wokeness."
///
/// The essay is argumentative, so the narration and on-screen language frame
/// its historical claims as Graham's thesis rather than neutral fact. Ten
/// chapters visualize the argument with timelines, systems diagrams, network
/// propagation, and a final "burden of proof" gate.
///
/// Full narrated render:
///   bash tools/make_origins_video.sh
public struct OriginsOfWokeness: RenderScene {
    // Generated from measured Kokoro clips by tools/origins_vo.py.
    static let durs: [Double] = [13, 14.2, 17.2, 19, 15, 19.7, 19.1, 17.7, 18, 17]
    static let cross = 0.55
    static let anchors: [Double] = {
        var out: [Double] = []
        var cursor = 0.0
        for d in durs {
            out.append(cursor)
            cursor += d - cross
        }
        return out
    }()

    public static let defaultDuration = anchors.last! + durs.last! // 164.9s

    // MARK: Palette

    static let bg = Color(red: 0.025, green: 0.031, blue: 0.047)
    static let ink = Color(red: 0.95, green: 0.95, blue: 0.91)
    static let dim = Color(red: 0.50, green: 0.54, blue: 0.61)
    static let faint = Color(red: 0.18, green: 0.21, blue: 0.27)
    static let cyan = Color(red: 0.20, green: 0.90, blue: 0.92)
    static let coral = Color(red: 1.0, green: 0.38, blue: 0.31)
    static let gold = Color(red: 1.0, green: 0.77, blue: 0.29)
    static let violet = Color(red: 0.63, green: 0.47, blue: 1.0)
    static let panel = Color(red: 0.052, green: 0.063, blue: 0.088)

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let a = anchors
        return ZStack {
            bg.ignoresSafeArea()
            editorialGrid.opacity(0.45)
            Timeline(t) {
                Clip(at: a[0], for: durs[0]) { l in wrap(l, durs[0]) { titleCard(l) } }
                Clip(at: a[1], for: durs[1]) { l in wrap(l, durs[1]) { thePrig(l) } }
                Clip(at: a[2], for: durs[2]) { l in wrap(l, durs[2]) { twoWaves(l) } }
                Clip(at: a[3], for: durs[3]) { l in wrap(l, durs[3]) { protestToPower(l) } }
                Clip(at: a[4], for: durs[4]) { l in wrap(l, durs[4]) { rulebook(l) } }
                Clip(at: a[5], for: durs[5]) { l in wrap(l, durs[5]) { outrageEngine(l) } }
                Clip(at: a[6], for: durs[6]) { l in wrap(l, durs[6]) { institutionalFlywheel(l) } }
                Clip(at: a[7], for: durs[7]) { l in wrap(l, durs[7]) { adoptionEpidemic(l) } }
                Clip(at: a[8], for: durs[8]) { l in wrap(l, durs[8]) { pluralism(l) } }
                Clip(at: a[9], for: durs[9]) { l in wrap(l, durs[9]) { antibodies(l) } }
                Clip(at: 0, for: duration) { l in footer(l, duration) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    public static func soundtrack(duration: Double) -> Score? {
        let a = anchors
        return Score(duration: duration) {
            drone(.a1, from: 0, for: duration, amp: 0.07)
            drone(.e2, from: a[2], for: a[5] - a[2] + 4, amp: 0.025)
            drone(.c2, from: a[5], for: a[8] - a[5] + 4, amp: 0.032)
            drone(.g1, from: a[8], for: duration - a[8], amp: 0.04)
            boom(at: 0.15, amp: 0.42, duration: 2.5)
            transitionHits(Array(a.dropFirst()))
            every(1.5, from: a[5], to: a[8]) { kick(at: $0, amp: 0.16) }
            boom(at: a[5], amp: 0.45, duration: 2.0)
            boom(at: a[9], amp: 0.72, duration: 3.0)
        }
    }

    static func transitionHits(_ times: [Double]) -> [ScoreEvent] {
        times.flatMap {
            crash(at: $0, amp: 0.075)
        }
    }

    // MARK: Shared

    static var editorialGrid: some View {
        ZStack {
            ForEach(0..<13, id: \.self) { i in
                Rectangle().fill(faint.opacity(0.22)).frame(width: 1, height: 1080)
                    .offset(x: CGFloat(i - 6) * 150)
            }
            ForEach(0..<9, id: \.self) { i in
                Rectangle().fill(faint.opacity(0.18)).frame(width: 1920, height: 1)
                    .offset(y: CGFloat(i - 4) * 120)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder @MainActor
    static func wrap<V: View>(_ t: Double, _ dur: Double,
                              @ViewBuilder content: () -> V) -> some View {
        let entry = Ease.easeInOut(Ease.clip(t, 0, cross))
        let exit = 1 - Ease.easeInOut(Ease.clip(t, dur - cross, dur))
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(entry * exit)
    }

    @ViewBuilder static func kicker(_ text: String, _ p: Double,
                                    color: Color = cyan) -> some View {
        HStack(spacing: 14) {
            Rectangle().fill(color).frame(width: 30, height: 4)
            Text(text)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(color)
        }
        .opacity(p)
        .offset(x: (1 - p) * -30)
    }

    @ViewBuilder static func bigWord(_ text: String, color: Color = ink,
                                     size: CGFloat = 110) -> some View {
        Text(text)
            .font(.custom("Inter-Black", size: size))
            .tracking(-4)
            .foregroundStyle(color)
    }

    @ViewBuilder static func mono(_ text: String, color: Color = dim,
                                  size: CGFloat = 22) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(color)
    }

    @ViewBuilder static func boxLabel(_ text: String, color: Color,
                                      width: CGFloat = 260) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(color)
            .frame(width: width, height: 58)
            .background(panel)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.75), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder static func connectingLine(_ from: CGPoint, _ to: CGPoint,
                                            color: Color, width: CGFloat = 2) -> some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    static func hash01(_ x: Double) -> Double {
        abs((sin(x * 91.731) * 43758.5453).truncatingRemainder(dividingBy: 1))
    }

    @ViewBuilder static func footer(_ t: Double, _ duration: Double) -> some View {
        VStack {
            Spacer()
            HStack {
                mono("PAUL GRAHAM · THE ORIGINS OF WOKENESS · VISUAL SUMMARY", size: 14)
                Spacer()
                mono(String(format: "%03.0f / %03.0f", t, duration), size: 14)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 24)
            ZStack(alignment: .leading) {
                Rectangle().fill(faint.opacity(0.6)).frame(height: 3)
                Rectangle().fill(cyan).frame(width: 1920 * CGFloat(t / duration), height: 3)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 00 Title

    @MainActor static func titleCard(_ t: Double) -> some View {
        let glow = Ease.easeOut(Ease.clip(t, 0, 2.5))
        let k = Ease.easeOut(Ease.clip(t, 0.25, 1.0))
        let a = Ease.easeOutBack(Ease.clip(t, 0.65, 1.8))
        let b = Ease.easeOutBack(Ease.clip(t, 1.1, 2.3))
        let sub = Ease.easeOut(Ease.clip(t, 2.0, 3.1))
        let question = Ease.easeOut(Ease.clip(t, 4.6, 5.8))
        return ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.swiftRender.interference(
                    .float2(1920, 1080), .float(Float(t * 0.28))))
                .opacity(glow * 0.17)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 6) {
                kicker("AN ATTRIBUTED VISUAL SUMMARY", k)
                    .padding(.bottom, 34)
                bigWord("THE ORIGINS", size: 142)
                    .opacity(a).offset(x: (1 - a) * -100)
                bigWord("OF WOKENESS", color: coral, size: 142)
                    .opacity(b).offset(x: (1 - b) * 100)
                Rectangle().fill(cyan).frame(width: 670 * sub, height: 7)
                    .padding(.vertical, 24)
                Text("Paul Graham · January 2025")
                    .font(.custom("Inter-Light", size: 38))
                    .foregroundStyle(dim)
                    .opacity(sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 150)

            HStack(spacing: 10) {
                mono("WHY THIS FORM", color: ink, size: 18)
                mono("·", color: coral, size: 18)
                mono("WHY THIS MOMENT", color: ink, size: 18)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .background(panel.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(cyan.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(question)
            .offset(x: 560, y: 375)
        }
    }

    // MARK: 01 The prig

    @MainActor static func thePrig(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let core = Ease.spring(max(0, t - 0.8), from: 0, to: 1, response: 0.7, dampingFraction: 0.62)
        let orbitP = Ease.easeOut(Ease.clip(t, 2.3, 4.0))
        let thesis = Ease.easeOut(Ease.clip(t, 6.4, 7.5))
        let rules = ["VICTORIAN\nVIRTUE", "ORTHODOX\nMARXISM", "SOCIAL\nJUSTICE"]
        return ZStack {
            kicker("THE RECURRING CHARACTER", k)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 130).padding(.top, 105)

            ZStack {
                Circle().stroke(faint, style: StrokeStyle(lineWidth: 2, dash: [7, 10]))
                    .frame(width: 610, height: 610)
                    .scaleEffect(orbitP)

                ForEach(0..<3, id: \.self) { i in
                    let angle = Double(i) * 120 + t * 8
                    VStack(spacing: 7) {
                        Circle().fill([gold, violet, coral][i]).frame(width: 18, height: 18)
                        mono(rules[i], color: ink, size: 16).multilineTextAlignment(.center)
                    }
                    .frame(width: 170, height: 95)
                    .background(panel.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke([gold, violet, coral][i].opacity(0.8)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .offset(x: cos(angle * .pi / 180) * 305,
                            y: sin(angle * .pi / 180) * 305)
                    .opacity(orbitP)
                }

                VStack(spacing: 6) {
                    bigWord("PRIG", color: ink, size: 104)
                    mono("MORAL ENFORCER", color: coral, size: 17)
                }
                .frame(width: 390, height: 240)
                .background(panel)
                .overlay(Circle().stroke(coral, lineWidth: 4))
                .clipShape(Circle())
                .scaleEffect(core)
            }
            .offset(x: -360, y: 45)

            VStack(alignment: .leading, spacing: 26) {
                mono("GRAHAM'S STARTING CLAIM", color: cyan, size: 18)
                bigWord("THE PERSON\nIS OLD.", size: 76)
                bigWord("THE RULEBOOK\nCHANGES.", color: coral, size: 76)
                HStack(spacing: 16) {
                    Rectangle().fill(cyan).frame(width: 92, height: 5)
                    mono("same impulse · different doctrine", color: dim, size: 18)
                }
            }
            .opacity(thesis)
            .offset(x: 440, y: 40)
        }
    }

    // MARK: 02 Two waves

    @MainActor static func twoWaves(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let axis = Ease.easeInOut(Ease.clip(t, 0.8, 2.0))
        let wave1 = Ease.easeInOut(Ease.clip(t, 2.1, 5.2))
        let wave2 = Ease.easeInOut(Ease.clip(t, 6.0, 10.0))
        let peak = Ease.easeOutBack(Ease.clip(t, 10.2, 11.2))
        let w: CGFloat = 1450, h: CGFloat = 460
        let points: [CGPoint] = [
            .init(x: 0, y: h * 0.94), .init(x: w * 0.18, y: h * 0.82),
            .init(x: w * 0.28, y: h * 0.25), .init(x: w * 0.38, y: h * 0.42),
            .init(x: w * 0.50, y: h * 0.88), .init(x: w * 0.65, y: h * 0.78),
            .init(x: w * 0.78, y: h * 0.38), .init(x: w * 0.91, y: h * 0.06),
            .init(x: w, y: h * 0.38),
        ]
        return VStack(alignment: .leading, spacing: 35) {
            kicker("GRAHAM'S HISTORICAL ARC", k)
            HStack(alignment: .lastTextBaseline) {
                bigWord("TWO WAVES.", size: 92)
                Spacer()
                mono("PUBLIC INTENSITY · CONCEPTUAL", color: dim, size: 16)
            }
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: .init(x: 0, y: h))
                    path.addLine(to: .init(x: w, y: h))
                }.trim(from: 0, to: axis).stroke(dim.opacity(0.7), lineWidth: 2)

                ForEach(0..<points.count - 1, id: \.self) { i in
                    let progress = i < 4 ? wave1 : wave2
                    connectingLine(points[i], points[i + 1],
                                   color: i < 4 ? violet : coral, width: 7)
                        .opacity(progress)
                }
                Circle().fill(coral).frame(width: 30, height: 30)
                    .position(points[7]).scaleEffect(peak)
                    .shadow(color: coral, radius: 22)
                mono("PEAK", color: coral, size: 17)
                    .position(x: points[7].x, y: points[7].y - 55)
                    .opacity(peak)

                ForEach(Array(["1960s", "1988", "2000", "2010s", "2020", "NOW"].enumerated()),
                        id: \.offset) { i, year in
                    let xs: [CGFloat] = [0, w * 0.28, w * 0.50, w * 0.72, w * 0.91, w]
                    mono(year, color: i == 4 ? coral : dim, size: 16)
                        .position(x: xs[i], y: h + 34)
                        .opacity(axis)
                }
                boxLabel("POLITICAL\nCORRECTNESS", color: violet, width: 300)
                    .position(x: w * 0.30, y: 80).opacity(wave1)
                boxLabel("SOCIAL MEDIA\nWAVE", color: coral, width: 300)
                    .position(x: w * 0.79, y: 205).opacity(wave2)
            }
            .frame(width: w, height: h + 60)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 150)
    }

    // MARK: 03 Protest to power

    @MainActor static func protestToPower(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let people = Ease.easeOut(Ease.clip(t, 0.8, 2.7))
        let travel = Ease.easeInOut(Ease.clip(t, 3.3, 8.0))
        let building = Ease.easeOutBack(Ease.clip(t, 7.0, 8.4))
        let swap = Ease.easeOut(Ease.clip(t, 10.0, 11.2))
        return ZStack {
            VStack(alignment: .leading, spacing: 18) {
                kicker("GRAHAM'S INSTITUTIONAL STORY", k)
                bigWord("PROTEST", color: violet, size: 82)
                mono("students · 1960s", color: dim, size: 17)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 125).padding(.top, 100)

            // Conveyor from street protest to institutional authority.
            Rectangle().fill(faint).frame(width: 1320, height: 5)
                .overlay(Rectangle().fill(cyan).frame(width: 1320 * travel, height: 5),
                         alignment: .leading)
                .offset(y: 115)

            ForEach(0..<7, id: \.self) { i in
                let p = Ease.easeOut(Ease.clip(t, 0.7 + Double(i) * 0.13, 1.5 + Double(i) * 0.13))
                let x = -650 + 1300 * travel
                VStack(spacing: 5) {
                    Circle().fill(i % 2 == 0 ? violet : cyan).frame(width: 34, height: 34)
                    Rectangle().fill(ink).frame(width: 50, height: 78)
                    Rectangle().fill(coral).frame(width: 78, height: 24)
                        .overlay(mono(["NO WAR", "POWER", "CHANGE"][i % 3], color: bg, size: 10))
                }
                .scaleEffect(0.75 + 0.25 * p)
                .opacity(people)
                .offset(x: CGFloat(x) + CGFloat(i) * 52.0, y: 80.0 + CGFloat(i % 2) * 14.0)
            }

            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3).fill(gold).frame(width: 105, height: 34)
                    }
                }
                PolygonRoof().fill(ink).frame(width: 680, height: 120)
                HStack(spacing: 42) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle().fill(ink).frame(width: 70, height: 290)
                    }
                }
                Rectangle().fill(ink).frame(width: 680, height: 35)
            }
            .scaleEffect(building)
            .offset(x: 510, y: 85)

            VStack(alignment: .leading, spacing: 12) {
                mono("THE TRANSFORMATION", color: cyan, size: 17)
                HStack(spacing: 22) {
                    boxLabel("SPEAK OUT", color: violet, width: 260)
                    bigWord("→", color: dim, size: 54)
                    boxLabel("ENFORCE", color: coral, width: 260)
                }
                mono("persuasion becomes procedure", color: dim, size: 18)
            }
            .opacity(swap)
            .offset(x: 0, y: 390)
        }
    }

    // MARK: 04 Rulebook

    @MainActor static func rulebook(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let stack = Ease.easeOut(Ease.clip(t, 0.8, 4.8))
        let replace = Ease.easeOut(Ease.clip(t, 6.0, 7.2))
        let thesis = Ease.easeOutBack(Ease.clip(t, 9.0, 10.2))
        let labels = ["APPROVED TERM", "NEW GUIDANCE", "BEST PRACTICE",
                      "UPDATED RULE", "INCLUSIVE GUIDE", "REVISED AGAIN"]
        return ZStack {
            VStack(alignment: .leading, spacing: 20) {
                kicker("MORAL ETIQUETTE", k, color: gold)
                bigWord("A MOVING\nRULEBOOK.", size: 92)
                mono("complex · visible · frequently changing", color: dim, size: 19)
            }
            .offset(x: -520, y: -130)

            ZStack {
                ForEach(0..<labels.count, id: \.self) { i in
                    let p = Ease.easeOut(Ease.clip(stack, Double(i) / 7, Double(i + 2) / 7))
                    let rot = Double(i - 3) * 2.1
                    HStack {
                        Circle().fill(i == labels.count - 1 ? coral : cyan).frame(width: 14, height: 14)
                        mono(labels[i], color: ink, size: 17)
                        Spacer()
                        mono("v\(i + 1).0", color: dim, size: 13)
                    }
                    .padding(.horizontal, 24)
                    .frame(width: 570, height: 78)
                    .background(panel)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        i == labels.count - 1 ? coral : faint, lineWidth: 2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .rotationEffect(.degrees(rot))
                    .offset(y: CGFloat(i - 3) * 65)
                    .opacity(p)
                    .offset(x: (1 - p) * 260)
                }
            }
            .offset(x: 455, y: -20)

            HStack(spacing: 28) {
                VStack(spacing: 7) {
                    mono("CHARACTER", color: dim, size: 16)
                    bigWord("?", color: dim, size: 90)
                }
                bigWord("→", color: faint, size: 70)
                VStack(spacing: 7) {
                    mono("ORTHODOXY", color: coral, size: 16)
                    bigWord("100", color: coral, size: 90)
                }
            }
            .padding(.horizontal, 38).padding(.vertical, 22)
            .background(panel.opacity(0.94))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(coral.opacity(0.6), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(replace)
            .offset(x: -400, y: 300)

            mono("ORTHODOXY CAN SUBSTITUTE FOR VIRTUE", color: gold, size: 24)
                .padding(.horizontal, 34).padding(.vertical, 18)
                .background(gold.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(gold))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(thesis).opacity(thesis)
                .offset(x: 430, y: 370)
        }
    }

    // MARK: 05 Outrage engine

    @MainActor static func outrageEngine(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let network = Ease.easeOut(Ease.clip(t, 0.8, 4.5))
        let outrage = Ease.easeInOut(Ease.clip(t, 4.4, 9.6))
        let metric = Ease.easeOutBack(Ease.clip(t, 9.6, 10.8))
        let center = CGPoint(x: 960, y: 535)
        return ZStack {
            kicker("THE SECOND WAVE'S ENGINE", k, color: coral)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 125).padding(.top, 100)

            ForEach(0..<34, id: \.self) { i in
                let angle = hash01(Double(i) + 4) * .pi * 2
                let radius = CGFloat(110 + hash01(Double(i) + 23) * 620)
                let pt = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                 y: center.y + CGFloat(sin(angle)) * radius * 0.55)
                let activated = Ease.easeOut(Ease.clip(outrage, Double(i) / 42,
                                                       Double(i + 8) / 42))
                connectingLine(center, pt, color: coral.opacity(0.12 + activated * 0.55),
                               width: CGFloat(1 + activated * 2))
                    .opacity(network)
                Circle()
                    .fill(activated > 0.3 ? coral : cyan)
                    .frame(width: CGFloat(14 + activated * 25),
                           height: CGFloat(14 + activated * 25))
                    .position(pt)
                    .opacity(network)
                    .shadow(color: coral.opacity(activated), radius: 15)
            }

            ZStack {
                Circle().fill(coral).frame(width: 135, height: 135)
                    .shadow(color: coral, radius: 42)
                bigWord("!", color: bg, size: 82)
            }
            .scaleEffect(0.85 + 0.15 * sin(t * 4))

            VStack(alignment: .leading, spacing: 10) {
                mono("OUTRAGE ADVANTAGE", color: coral, size: 17)
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    bigWord("3×", color: coral, size: 132)
                    mono("MORE LIKELY TO BE UPVOTED", color: ink, size: 18)
                }
                mono("Graham's forum observation · 2007–2014", color: dim, size: 15)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .background(bg.opacity(0.90))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(coral.opacity(0.7), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(metric)
            .offset(x: 445, y: 300)
        }
    }

    // MARK: 06 Institutional flywheel

    @MainActor static func institutionalFlywheel(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let ring = Ease.easeOut(Ease.clip(t, 0.8, 3.0))
        let labels = ["DETECT\nIMPROPRIETY", "WRITE\nGUIDANCE", "COPY BEST\nPRACTICE", "EXPAND\nMANDATE"]
        return ZStack {
            VStack(alignment: .leading, spacing: 12) {
                kicker("THE INSTITUTIONAL FLYWHEEL", k, color: gold)
                bigWord("FEAR MOVES\nFASTER.", size: 82)
                mono("a small committed group → a cautious majority", color: dim, size: 18)
            }
            .offset(x: -500, y: -270)

            ZStack {
                Circle().stroke(faint, style: StrokeStyle(lineWidth: 8, dash: [18, 16]))
                    .frame(width: 610, height: 610)
                    .rotationEffect(.degrees(t * 12))
                    .scaleEffect(ring)

                ForEach(0..<4, id: \.self) { i in
                    let angle = Double(i) * 90 - 90
                    let p = Ease.easeOutBack(Ease.clip(t, 1.4 + Double(i) * 0.55,
                                                       2.7 + Double(i) * 0.55))
                    boxLabel(labels[i], color: [coral, gold, violet, cyan][i], width: 250)
                        .offset(x: cos(angle * .pi / 180) * 330,
                                y: sin(angle * .pi / 180) * 330)
                        .scaleEffect(p).opacity(p)
                }

                Circle().fill(panel).frame(width: 300, height: 300)
                    .overlay(Circle().stroke(gold, lineWidth: 3))
                VStack(spacing: 6) {
                    mono("FEEDBACK", color: gold, size: 17)
                    bigWord("LOOP", color: ink, size: 66)
                }
            }
            .offset(x: 330, y: 80)

            VStack(alignment: .leading, spacing: 15) {
                mono("ORGANIZATION WITHOUT A STRONG COUNTERWEIGHT", color: dim, size: 15)
                ForEach(0..<8, id: \.self) { i in
                    let p = Ease.easeOut(Ease.clip(t, 6 + Double(i) * 0.25,
                                                   7.1 + Double(i) * 0.25))
                    HStack(spacing: 12) {
                        Circle().fill(i < 2 ? coral : dim).frame(width: 18, height: 18)
                        Rectangle().fill(i < 2 ? coral : dim.opacity(0.5))
                            .frame(width: CGFloat(80 + i * 25) * p, height: 5)
                    }
                }
            }
            .padding(28).frame(width: 500, alignment: .leading)
            .background(panel.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(faint, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .offset(x: -510, y: 240)
        }
    }

    // MARK: 07 Adoption epidemic

    @MainActor static func adoptionEpidemic(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let phase1 = Ease.easeInOut(Ease.clip(t, 1.3, 4.3))
        let phase2 = Ease.easeInOut(Ease.clip(t, 4.8, 9.0))
        let phase3 = Ease.easeInOut(Ease.clip(t, 9.2, 13.4))
        return ZStack {
            VStack(alignment: .leading, spacing: 10) {
                kicker("THE ADOPTION CYCLE", k, color: violet)
                bigWord("A NORM SPREADS.", size: 84)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 125).padding(.top, 95)

            ForEach(0..<96, id: \.self) { i in
                let col = i % 16, row = i / 16
                let x = CGFloat(col - 8) * 78 + 38
                let y = CGFloat(row - 3) * 82 + 50
                let threshold = Double(i) / 96
                let active: Double = i < 8
                    ? Ease.easeOut(Ease.clip(phase1, threshold * 0.2, threshold * 0.2 + 0.3))
                    : Ease.easeOut(Ease.clip(phase2 + phase3 * 0.8, threshold * 0.8,
                                             threshold * 0.8 + 0.18))
                Circle()
                    .fill(active > 0.1 ? coral : faint)
                    .frame(width: CGFloat(25 + active * 20),
                           height: CGFloat(25 + active * 20))
                    .shadow(color: coral.opacity(active), radius: 12)
                    .offset(x: x, y: y)
            }

            HStack(spacing: 18) {
                phaseChip("01", "ZEALOTS\nDEFINE", phase1, coral)
                bigWord("→", color: faint, size: 48)
                phaseChip("02", "EARLY ADOPTERS\nSIGNAL", phase2, violet)
                bigWord("→", color: faint, size: 48)
                phaseChip("03", "MAJORITY\nCOMPLIES", phase3, gold)
            }
            .offset(y: 380)
        }
    }

    @ViewBuilder static func phaseChip(_ number: String, _ text: String,
                                       _ p: Double, _ color: Color) -> some View {
        HStack(spacing: 16) {
            bigWord(number, color: color, size: 48)
            mono(text, color: ink, size: 15).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 22).frame(width: 330, height: 92)
        .background(panel)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.7), lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .opacity(p).offset(y: (1 - p) * 30)
    }

    // MARK: 08 Pluralism

    @MainActor static func pluralism(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let curve = Ease.easeInOut(Ease.clip(t, 0.8, 5.3))
        let peak = Ease.easeOutBack(Ease.clip(t, 4.2, 5.3))
        let chamber = Ease.easeOut(Ease.clip(t, 7.0, 8.6))
        let w: CGFloat = 760, h: CGFloat = 360
        return ZStack {
            VStack(alignment: .leading, spacing: 14) {
                kicker("PEAK, RETREAT, RESPONSE", k, color: cyan)
                bigWord("PLURALISM.", size: 92)
                mono("beliefs may coexist · institutions do not impose one", color: dim, size: 18)
            }
            .offset(x: -430, y: -320)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addCurve(to: CGPoint(x: w * 0.72, y: 30),
                                  control1: CGPoint(x: w * 0.25, y: h),
                                  control2: CGPoint(x: w * 0.55, y: 20))
                    path.addCurve(to: CGPoint(x: w, y: h * 0.45),
                                  control1: CGPoint(x: w * 0.82, y: 60),
                                  control2: CGPoint(x: w * 0.92, y: h * 0.45))
                }
                .trim(from: 0, to: curve)
                .stroke(coral, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                Circle().fill(coral).frame(width: 28, height: 28)
                    .position(x: w * 0.72, y: 30).scaleEffect(peak)
                mono("2020", color: coral, size: 16).position(x: w * 0.72, y: 0).opacity(peak)
                Rectangle().fill(faint).frame(width: w, height: 2).offset(y: h)
            }
            .frame(width: w, height: h)
            .offset(x: -425, y: 80)

            ZStack {
                RoundedRectangle(cornerRadius: 24).stroke(ink.opacity(0.65), lineWidth: 4)
                    .frame(width: 620, height: 520)
                ForEach(0..<7, id: \.self) { i in
                    let colors = [cyan, violet, gold, coral, ink, Color.green, Color.blue]
                    let angle = Double(i) / 7 * .pi * 2 + t * 0.06
                    let r = 115 + hash01(Double(i) + 90) * 105
                    Circle().fill(colors[i]).frame(width: 62, height: 62)
                        .offset(x: cos(angle) * r, y: sin(angle) * r)
                }
                VStack(spacing: 5) {
                    mono("SHARED", color: dim, size: 14)
                    bigWord("SPACE", color: ink, size: 52)
                }
            }
            .scaleEffect(chamber).opacity(chamber)
            .offset(x: 500, y: 100)
        }
    }

    // MARK: 09 Antibodies

    @MainActor static func antibodies(_ t: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let gate = Ease.easeOutBack(Ease.clip(t, 0.8, 2.2))
        let burden = Ease.easeOut(Ease.clip(t, 3.0, 4.2))
        let final = Ease.easeOut(Ease.clip(t, 7.2, 9.0))
        let underline = Ease.easeInOut(Ease.clip(t, 9.2, 10.5))
        return ZStack {
            kicker("THE GENERAL ANTIBODY", k, color: cyan)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 125).padding(.top, 95)

            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 18) {
                    ForEach(Array(["NEW HERESY", "CLAIMED HARM", "BAN THIS",
                                   "FORBID THAT"].enumerated()), id: \.offset) { i, text in
                        let p = Ease.easeOut(Ease.clip(t, 1.5 + Double(i) * 0.35,
                                                       2.6 + Double(i) * 0.35))
                        boxLabel(text, color: coral, width: 250)
                            .opacity(p).offset(x: (1 - p) * -120)
                    }
                }

                VStack(spacing: 8) {
                    Rectangle().fill(ink).frame(width: 36, height: 520)
                    boxLabel("BURDEN\nOF PROOF", color: gold, width: 310)
                    Rectangle().fill(ink).frame(width: 36, height: 520)
                }
                .scaleEffect(gate)
                .padding(.horizontal, 75)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(["EVIDENCE", "ARGUMENT", "OPEN DEBATE",
                                   "TRUE SPEECH"].enumerated()), id: \.offset) { i, text in
                        let p = Ease.easeOut(Ease.clip(t, 4.0 + Double(i) * 0.4,
                                                       5.0 + Double(i) * 0.4))
                        boxLabel(text, color: cyan, width: 250)
                            .opacity(p).offset(x: (1 - p) * 120)
                    }
                }
            }
            .opacity(burden)
            .offset(y: -30)

            VStack(alignment: .leading, spacing: 8) {
                mono("GRAHAM'S CLOSING TEST", color: cyan, size: 17)
                bigWord("THE NUMBER OF TRUE THINGS", size: 66)
                bigWord("WE CANNOT SAY", color: coral, size: 66)
                bigWord("SHOULD NOT INCREASE.", size: 66)
                Rectangle().fill(cyan).frame(width: 1040 * underline, height: 7)
                    .padding(.top, 12)
            }
            .opacity(final)
            .padding(.horizontal, 45).padding(.vertical, 32)
            .background(bg.opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.55), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .offset(y: 300)
        }
    }
}

private struct PolygonRoof: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
