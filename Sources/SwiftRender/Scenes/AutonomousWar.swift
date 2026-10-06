import SwiftUI

/// AutonomousWar — a researched strategic explainer on autonomous systems,
/// how they change warfare, and how India should evolve.
///
/// The film is deliberately non-operational: it focuses on force design,
/// resilience, human control, and national innovation capacity.
///
/// Full narrated render:
///   bash tools/make_autonomous_war_video.sh
public struct AutonomousWar: RenderScene {
    // Generated from measured Kokoro clips by tools/autonomous_war_vo.py.
    static let durs: [Double] = [15.2, 18.9, 19.3, 17.5, 20.9, 18.5, 20.7, 22, 23.7, 23, 22.8, 21.7]
    static let cross = 0.55
    static let anchors: [Double] = {
        var result: [Double] = []
        var cursor = 0.0
        for duration in durs {
            result.append(cursor)
            cursor += duration - cross
        }
        return result
    }()
    public static let defaultDuration = anchors.last! + durs.last! // 238.1s

    static let black = Color(red: 0.018, green: 0.022, blue: 0.026)
    static let panel = Color(red: 0.035, green: 0.043, blue: 0.048)
    static let ink = Color(red: 0.92, green: 0.94, blue: 0.92)
    static let dim = Color(red: 0.42, green: 0.48, blue: 0.49)
    static let grid = Color(red: 0.13, green: 0.18, blue: 0.19)
    static let signal = Color(red: 0.50, green: 0.98, blue: 0.70)
    static let cyan = Color(red: 0.20, green: 0.82, blue: 0.88)
    static let amber = Color(red: 1.0, green: 0.60, blue: 0.16)
    static let danger = Color(red: 1.0, green: 0.31, blue: 0.25)
    static let india = Color(red: 1.0, green: 0.47, blue: 0.10)

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let a = anchors
        return ZStack {
            black.ignoresSafeArea()
            commandGrid.opacity(0.45)
            Timeline(t) {
                Clip(at: a[0], for: durs[0]) { l in wrap(l, durs[0]) { title(l) } }
                Clip(at: a[1], for: durs[1]) { l in wrap(l, durs[1]) { spectrum(l) } }
                Clip(at: a[2], for: durs[2]) { l in wrap(l, durs[2]) { economics(l) } }
                Clip(at: a[3], for: durs[3]) { l in wrap(l, durs[3]) { decisionLoop(l) } }
                Clip(at: a[4], for: durs[4]) { l in wrap(l, durs[4]) { attritableMass(l) } }
                Clip(at: a[5], for: durs[5]) { l in wrap(l, durs[5]) { contestedSpectrum(l) } }
                Clip(at: a[6], for: durs[6]) { l in wrap(l, durs[6]) { acrossDomains(l) } }
                Clip(at: a[7], for: durs[7]) { l in wrap(l, durs[7]) { humanControl(l) } }
                Clip(at: a[8], for: durs[8]) { l in wrap(l, durs[8]) { indiaGeography(l) } }
                Clip(at: a[9], for: durs[9]) { l in wrap(l, durs[9]) { indiaFoundations(l) } }
                Clip(at: a[10], for: durs[10]) { l in wrap(l, durs[10]) { fiveMoves(l) } }
                Clip(at: a[11], for: durs[11]) { l in wrap(l, durs[11]) { finale(l) } }
                Clip(at: 0, for: duration) { l in hud(l, duration) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    public static func soundtrack(duration: Double) -> Score? {
        let a = anchors
        return Score(duration: duration) {
            drone(.a1, from: 0, for: duration, amp: 0.075)
            drone(.e2, from: a[2], for: a[5] - a[2] + 5, amp: 0.024)
            drone(.c2, from: a[5], for: a[8] - a[5] + 5, amp: 0.033)
            drone(.g1, from: a[8], for: duration - a[8], amp: 0.038)
            cutHits(Array(a.dropFirst()))
            every(1.2, from: a[3], to: a[7]) { kick(at: $0, amp: 0.15) }
            boom(at: a[4], amp: 0.45, duration: 2.0)
            boom(at: a[8], amp: 0.55, duration: 2.5)
            boom(at: a[11], amp: 0.8, duration: 3.2)
        }
    }

    static func cutHits(_ times: [Double]) -> [ScoreEvent] {
        times.flatMap {
            crash(at: $0, amp: 0.065)
        }
    }

    // MARK: Shared visual system

    static var commandGrid: some View {
        ZStack {
            ForEach(0..<17, id: \.self) { i in
                Rectangle().fill(grid).frame(width: 1, height: 1080)
                    .offset(x: CGFloat(i - 8) * 120)
            }
            ForEach(0..<11, id: \.self) { i in
                Rectangle().fill(grid).frame(width: 1920, height: 1)
                    .offset(y: CGFloat(i - 5) * 108)
            }
        }.ignoresSafeArea()
    }

    @ViewBuilder @MainActor
    static func wrap<V: View>(_ t: Double, _ duration: Double,
                              @ViewBuilder content: () -> V) -> some View {
        let entry = Ease.easeInOut(Ease.clip(t, 0, cross))
        let exit = 1 - Ease.easeInOut(Ease.clip(t, duration - cross, duration))
        content().frame(maxWidth: .infinity, maxHeight: .infinity).opacity(entry * exit)
    }

    @ViewBuilder static func imageBackdrop(_ name: String, opacity: Double = 0.62) -> some View {
        bundledImage(name)
            .resizable()
            .scaledToFill()
            .frame(width: 1920, height: 1080)
            .clipped()
            .overlay(
                LinearGradient(colors: [black.opacity(0.15), black.opacity(0.50), black.opacity(0.92)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
            )
            .overlay(black.opacity(1 - opacity))
            .ignoresSafeArea()
    }

    @ViewBuilder static func eyebrow(_ text: String, _ p: Double,
                                     color: Color = signal) -> some View {
        HStack(spacing: 14) {
            Rectangle().fill(color).frame(width: 34, height: 3)
            Text(text)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(color)
        }
        .opacity(p).offset(x: (1 - p) * -28)
    }

    @ViewBuilder static func titleText(_ text: String, color: Color = ink,
                                       size: CGFloat = 104) -> some View {
        Text(text)
            .font(.custom("Inter-Black", size: size))
            .tracking(-4)
            .foregroundStyle(color)
    }

    @ViewBuilder static func mono(_ text: String, color: Color = dim,
                                  size: CGFloat = 17) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(color)
    }

    @ViewBuilder static func card(_ title: String, _ subtitle: String,
                                  color: Color = signal, width: CGFloat = 320) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(color).frame(width: 34, height: 3)
            mono(title, color: ink, size: 17)
            mono(subtitle, color: dim, size: 12)
        }
        .padding(22).frame(width: width, height: 128, alignment: .leading)
        .background(panel.opacity(0.96))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder static func sourceTag(_ text: String) -> some View {
        mono(text, color: dim, size: 11)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(black.opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(grid))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder static func hud(_ t: Double, _ duration: Double) -> some View {
        VStack {
            HStack {
                mono("AUTONOMOUS WARFARE / STRATEGIC SYSTEMS BRIEF", color: dim, size: 12)
                Spacer()
                mono("UNCLASSIFIED / VISUAL ANALYSIS", color: dim, size: 12)
            }.padding(.horizontal, 42).padding(.top, 28)
            Spacer()
            HStack {
                mono("RESEARCHED JUNE 2026", color: dim, size: 11)
                Spacer()
                mono(String(format: "%03.0f / %03.0f", t, duration), color: dim, size: 11)
            }.padding(.horizontal, 42).padding(.bottom, 21)
            ZStack(alignment: .leading) {
                Rectangle().fill(grid).frame(height: 3)
                Rectangle().fill(signal).frame(width: 1920 * CGFloat(t / duration), height: 3)
            }
        }.ignoresSafeArea()
    }

    @ViewBuilder static func line(_ from: CGPoint, _ to: CGPoint,
                                  color: Color, width: CGFloat = 2) -> some View {
        Path { p in p.move(to: from); p.addLine(to: to) }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    static func hash01(_ x: Double) -> Double {
        abs((sin(x * 93.71) * 43758.5453).truncatingRemainder(dividingBy: 1))
    }

    // MARK: 00 Title

    @MainActor static func title(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.2, 1.0))
        let a = Ease.easeOutBack(Ease.clip(t, 0.7, 1.9))
        let b = Ease.easeOutBack(Ease.clip(t, 1.2, 2.5))
        let sub = Ease.easeOut(Ease.clip(t, 2.4, 3.5))
        let scan = Ease.easeInOut(Ease.clip(t, 3.4, 6.0))
        return ZStack {
            imageBackdrop("autonomy-swarm", opacity: 0.78)
            Rectangle().fill(signal.opacity(0.7)).frame(width: 3, height: 1080)
                .offset(x: -960 + scan * 1920)
                .shadow(color: signal, radius: 12)
            VStack(alignment: .leading, spacing: 2) {
                eyebrow("THE SOFTWARE-DEFINED BATTLEFIELD", e)
                    .padding(.bottom, 28)
                titleText("AUTONOMOUS", size: 126).opacity(a).offset(x: (1 - a) * -90)
                titleText("WARFARE", color: signal, size: 154)
                    .opacity(b).offset(x: (1 - b) * 90)
                Rectangle().fill(amber).frame(width: 630 * sub, height: 6).padding(.vertical, 20)
                mono("HOW WAR CHANGES / HOW INDIA SHOULD EVOLVE", color: ink, size: 21)
                    .opacity(sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 130)
            .offset(y: 70)
        }
    }

    // MARK: 01 Autonomy spectrum

    @MainActor static func spectrum(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let axis = Ease.easeInOut(Ease.clip(t, 0.8, 2.2))
        let steps = ["REMOTE\nCONTROL", "ASSISTED\nOPERATION", "SUPERVISED\nAUTONOMY", "MISSION-LEVEL\nAUTONOMY"]
        return VStack(alignment: .leading, spacing: 34) {
            eyebrow("AUTONOMY IS A SPECTRUM", e)
            HStack(alignment: .lastTextBaseline) {
                titleText("NOT A BINARY.", size: 94)
                Spacer()
                mono("HUMAN AUTHORITY REMAINS THE ANCHOR", color: amber, size: 15)
            }
            ZStack(alignment: .leading) {
                Rectangle().fill(grid).frame(width: 1500, height: 5)
                Rectangle().fill(signal).frame(width: 1500 * axis, height: 5)
                ForEach(0..<4, id: \.self) { i in
                    let p = Ease.easeOutBack(Ease.clip(t, 1.5 + Double(i) * 0.75,
                                                       2.8 + Double(i) * 0.75))
                    VStack(spacing: 20) {
                        Circle().fill(i < 3 ? cyan : signal).frame(width: 32, height: 32)
                            .shadow(color: signal, radius: 14)
                        card(steps[i], ["PILOT DIRECTS", "SOFTWARE ASSISTS", "HUMAN SUPERVISES",
                                       "SYSTEM EXECUTES INTENT"][i],
                             color: i == 3 ? signal : cyan, width: 320)
                    }
                    .offset(x: CGFloat(i) * 390)
                    .opacity(p).offset(y: (1 - p) * 30)
                }
            }.frame(width: 1500, height: 220)
            HStack(spacing: 14) {
                card("ALREADY COMMON", "stabilization · routes · sensor fusion", color: cyan, width: 470)
                card("EMERGING", "edge perception · coordination · degraded-link operation",
                     color: signal, width: 520)
                card("GOVERNANCE QUESTION", "where human judgment must remain", color: amber, width: 500)
            }.opacity(Ease.easeOut(Ease.clip(t, 7.0, 8.2)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 145)
    }

    // MARK: 02 Economics

    @MainActor static func economics(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let reveal = Ease.easeOut(Ease.clip(t, 0.8, 3.0))
        let gridP = Ease.easeOut(Ease.clip(t, 3.5, 8.5))
        let thesis = Ease.easeOutBack(Ease.clip(t, 9.0, 10.2))
        return ZStack {
            imageBackdrop("autonomy-swarm", opacity: 0.42)
            VStack(alignment: .leading, spacing: 14) {
                eyebrow("THE NEW ECONOMICS", e, color: amber)
                titleText("CHEAP SENSING.", size: 86)
                titleText("PERSISTENT RISK.", color: amber, size: 86)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 125).padding(.top, 100).opacity(reveal)

            HStack(alignment: .bottom, spacing: 44) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8).fill(amber).frame(width: 170, height: 400)
                    mono("TRADITIONAL\nPLATFORM", color: ink, size: 15).multilineTextAlignment(.center)
                }
                VStack(spacing: 12) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<18, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(signal)
                                .frame(width: 20, height: CGFloat(45 + (i % 4) * 20))
                        }
                    }
                    mono("ATTRITABLE MASS", color: ink, size: 15)
                }
            }
            .padding(26).background(black.opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(grid))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .offset(x: -530, y: 220)
            .opacity(thesis)

            ZStack {
                ForEach(0..<48, id: \.self) { i in
                    let col = i % 8, row = i / 8
                    let p = Ease.easeOut(Ease.clip(gridP, Double(i) / 58, Double(i + 10) / 58))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(p > 0.3 ? danger.opacity(0.78) : grid)
                        .frame(width: 72, height: 54)
                        .overlay(mono(p > 0.3 ? "SEEN" : "—", color: p > 0.3 ? ink : dim, size: 9))
                        .offset(x: CGFloat(col - 4) * 82 + 40, y: CGFloat(row - 3) * 64 + 30)
                }
                mono("PERSISTENT OBSERVATION MAKES THE FIELD MORE TRANSPARENT",
                     color: ink, size: 14)
                    .padding(15).background(black.opacity(0.9))
                    .offset(y: 265)
            }
            .offset(x: 470, y: 170)
            sourceTag("EVIDENCE BASE / UKRAINE / RUSI + CSIS")
                .offset(x: 665, y: 430)
        }
    }

    // MARK: 03 Decision loop

    @MainActor static func decisionLoop(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let ring = Ease.easeOut(Ease.clip(t, 0.8, 3.0))
        let compress = Ease.easeInOut(Ease.clip(t, 5.0, 10.0))
        let labels = ["SENSE", "UNDERSTAND", "DECIDE", "ACT"]
        return ZStack {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("THE DECISIVE SYSTEM", e)
                titleText("THE LOOP.", size: 100)
                mono("not one drone · a connected decision architecture", color: dim, size: 17)
            }.offset(x: -560, y: -310)

            ZStack {
                Circle().stroke(grid, style: StrokeStyle(lineWidth: 7, dash: [18, 14]))
                    .frame(width: 680 - compress * 140, height: 680 - compress * 140)
                    .rotationEffect(.degrees(t * 14))
                    .scaleEffect(ring)
                ForEach(0..<4, id: \.self) { i in
                    let angle = Double(i) * 90 - 90 + t * (4 + compress * 5)
                    card(labels[i], ["sensors", "software", "command", "effects"][i],
                         color: [cyan, signal, amber, danger][i], width: 230)
                        .offset(x: cos(angle * .pi / 180) * (330 - compress * 70),
                                y: sin(angle * .pi / 180) * (330 - compress * 70))
                }
                Circle().fill(panel).frame(width: 310, height: 310)
                    .overlay(Circle().stroke(signal, lineWidth: 3))
                VStack(spacing: 7) {
                    mono("HUMAN TEAM", color: signal, size: 16)
                    titleText("INTENT", size: 54)
                    mono("judgment · priorities · limits", color: dim, size: 12)
                }
            }
            .offset(x: 330, y: 70)

            VStack(alignment: .leading, spacing: 16) {
                mono("AUTONOMY COMPRESSES TIME", color: amber, size: 16)
                HStack(alignment: .bottom, spacing: 14) {
                    Rectangle().fill(dim).frame(width: 430 * (1 - compress) + 90, height: 20)
                    mono(String(format: "%.1f×", 1 + compress * 4), color: amber, size: 32)
                }
                mono("one team supervises more machines", color: ink, size: 15)
            }
            .padding(26).background(panel.opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(amber.opacity(0.7)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .offset(x: -500, y: 250)
        }
    }

    // MARK: 04 Attritable mass

    @MainActor static func attritableMass(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let mass = Ease.easeOut(Ease.clip(t, 1.3, 7.5))
        let source = Ease.easeOut(Ease.clip(t, 9.0, 10.0))
        return VStack(alignment: .leading, spacing: 25) {
            eyebrow("FROM EXQUISITE SCARCITY TO ATTRITABLE MASS", e, color: amber)
            HStack(alignment: .lastTextBaseline) {
                titleText("QUANTITY", color: amber, size: 100)
                titleText("BECOMES A FEATURE.", size: 80)
            }
            HStack(spacing: 50) {
                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 24).stroke(ink, lineWidth: 4)
                        .frame(width: 420, height: 250)
                        .overlay(titleText("1", color: ink, size: 140))
                    mono("HIGH-COST / HARD TO RISK", color: dim, size: 15)
                }
                titleText("→", color: grid, size: 70)
                ZStack {
                    ForEach(0..<100, id: \.self) { i in
                        let col = i % 10, row = i / 10
                        let p = Ease.easeOut(Ease.clip(mass, Double(i) / 115, Double(i + 14) / 115))
                        RoundedRectangle(cornerRadius: 4).fill(signal.opacity(0.25 + 0.75 * p))
                            .frame(width: 50, height: 34)
                            .offset(x: CGFloat(col - 5) * 60 + 30, y: CGFloat(row - 5) * 44 + 22)
                            .opacity(p)
                    }
                }.frame(width: 620, height: 470)
                VStack(alignment: .leading, spacing: 14) {
                    card("NETWORKED", "coordination creates system value", color: signal, width: 370)
                    card("REPLACEABLE", "loss does not collapse the force", color: amber, width: 370)
                    card("CHEAP ENOUGH TO RISK", "mass changes the cost exchange", color: cyan, width: 370)
                }
            }
            HStack {
                sourceTag("U.S. DOD REPLICATOR / THOUSANDS ACROSS MULTIPLE DOMAINS")
                Spacer()
                mono("MASS WITHOUT SOFTWARE IS ONLY INVENTORY", color: danger, size: 15)
            }.opacity(source)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 130)
    }

    // MARK: 05 Contested spectrum

    @MainActor static func contestedSpectrum(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let jam = Ease.easeInOut(Ease.clip(t, 2.0, 7.0))
        let edge = Ease.easeOutBack(Ease.clip(t, 8.0, 9.2))
        return ZStack {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("THE SPECTRUM FIGHTS BACK", e, color: danger)
                titleText("LINKS BREAK.", color: danger, size: 92)
                mono("jamming · spoofing · degraded communications", color: dim, size: 17)
            }.offset(x: -500, y: -310)

            ZStack {
                Circle().fill(panel).frame(width: 170, height: 170)
                    .overlay(Circle().stroke(cyan, lineWidth: 3))
                    .overlay(mono("CONTROL", color: cyan, size: 15))
                    .offset(x: -570)
                Circle().fill(panel).frame(width: 170, height: 170)
                    .overlay(Circle().stroke(signal, lineWidth: 3))
                    .overlay(mono("SYSTEM", color: signal, size: 15))
                    .offset(x: 570)
                ForEach(0..<7, id: \.self) { i in
                    line(CGPoint(x: 390, y: 540 + CGFloat(i - 3) * 14),
                         CGPoint(x: 1530, y: 540 + CGFloat(i - 3) * 14),
                         color: i < Int(jam * 7) ? danger : cyan.opacity(0.55), width: 3)
                }
                ForEach(0..<5, id: \.self) { i in
                    let x = CGFloat(i - 2) * 130
                    Path { p in
                        p.move(to: CGPoint(x: 930 + x, y: 380))
                        p.addLine(to: CGPoint(x: 990 + x, y: 700))
                    }.stroke(danger.opacity(jam), lineWidth: 8)
                }
            }

            HStack(spacing: 14) {
                card("ONBOARD PERCEPTION", "understand locally", color: signal, width: 350)
                card("RESILIENT NAVIGATION", "continue when links fail", color: signal, width: 350)
                card("GRACEFUL FAILURE", "degrade safely", color: amber, width: 350)
            }
            .scaleEffect(edge).opacity(edge)
            .offset(y: 360)
        }
    }

    // MARK: 06 Across domains

    @MainActor static func acrossDomains(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let cards = Ease.easeOut(Ease.clip(t, 1.0, 5.0))
        let shift = Ease.easeInOut(Ease.clip(t, 5.0, 10.0))
        return ZStack {
            imageBackdrop("autonomy-maritime", opacity: 0.56)
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("ONE LOGIC / MULTIPLE DOMAINS", e)
                titleText("MOVE RISK.", size: 92)
                titleText("MULTIPLY REACH.", color: signal, size: 92)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 125).padding(.top, 95)

            HStack(spacing: 20) {
                card("AIR", "persistent sensing", color: cyan, width: 360)
                card("SEA", "distributed presence", color: signal, width: 360)
                card("LAND", "logistics through exposure", color: amber, width: 360)
            }
            .opacity(cards).offset(y: 345)

            HStack(spacing: 28) {
                mono("PERSON AT RISK", color: danger, size: 16)
                Rectangle().fill(danger).frame(width: 420 * (1 - shift), height: 5)
                titleText("→", color: ink, size: 46)
                Rectangle().fill(signal).frame(width: 420 * shift, height: 5)
                mono("MACHINE AT RISK", color: signal, size: 16)
            }
            .padding(24).background(black.opacity(0.88))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(grid))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .offset(y: 470)
            sourceTag("BLACK SEA EVIDENCE / RUSI").offset(x: 680, y: 450)
        }
    }

    // MARK: 07 Human control

    @MainActor static func humanControl(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let gate = Ease.easeOutBack(Ease.clip(t, 1.0, 2.4))
        let sides = Ease.easeOut(Ease.clip(t, 3.0, 6.0))
        let rule = Ease.easeOut(Ease.clip(t, 8.0, 9.2))
        return ZStack {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("CAPABILITY REQUIRES CONSTRAINT", e, color: danger)
                titleText("HUMAN JUDGMENT", size: 82)
                titleText("IS NOT LATENCY.", color: signal, size: 82)
            }.offset(x: -410, y: -330)

            VStack(spacing: 0) {
                Rectangle().fill(ink).frame(width: 28, height: 270)
                card("MEANINGFUL HUMAN CONTROL", "intent · context · accountability",
                     color: amber, width: 440)
                Rectangle().fill(ink).frame(width: 28, height: 270)
            }.scaleEffect(gate)

            VStack(alignment: .trailing, spacing: 18) {
                card("UNPREDICTABLE BEHAVIOR", "prohibit systems whose effects cannot be understood",
                     color: danger, width: 430)
                card("TARGETING PEOPLE", "ICRC recommends prohibition", color: danger, width: 430)
            }.opacity(sides).offset(x: -550, y: 120)

            VStack(alignment: .leading, spacing: 18) {
                card("SUPERVISED FUNCTIONS", "navigation · sensing · coordination",
                     color: signal, width: 430)
                card("CLEAR ACCOUNTABILITY", "people and institutions remain responsible",
                     color: signal, width: 430)
            }.opacity(sides).offset(x: 550, y: 120)

            HStack(spacing: 18) {
                Rectangle().fill(amber).frame(width: 55, height: 4)
                mono("THE FASTER THE SYSTEM, THE CLEARER THE RULES MUST BE",
                     color: ink, size: 17)
            }
            .opacity(rule).offset(y: 425)
            sourceTag("ICRC POSITION ON AUTONOMOUS WEAPON SYSTEMS").offset(x: 620, y: 450)
        }
    }

    // MARK: 08 India geography

    @MainActor static func indiaGeography(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let nodes = Ease.easeOut(Ease.clip(t, 1.0, 7.0))
        let thesis = Ease.easeOut(Ease.clip(t, 8.0, 9.3))
        return ZStack {
            imageBackdrop("autonomy-himalaya", opacity: 0.62)
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("INDIA / GEOGRAPHY DEMANDS DEPTH", e, color: india)
                titleText("HIGH ALTITUDE.", size: 78)
                titleText("VAST OCEAN.", color: india, size: 78)
                titleText("LONG COASTLINE.", size: 78)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 120).padding(.top, 90)

            ForEach(0..<14, id: \.self) { i in
                let x = 910 + hash01(Double(i) + 5) * 850
                let y = 250 + hash01(Double(i) + 30) * 520
                let p = Ease.easeOut(Ease.clip(nodes, Double(i) / 18, Double(i + 5) / 18))
                Circle().fill(i % 3 == 0 ? india : signal).frame(width: 16 + p * 18, height: 16 + p * 18)
                    .position(x: x, y: y)
                    .shadow(color: signal.opacity(p), radius: 13)
                    .opacity(p)
            }

            VStack(alignment: .leading, spacing: 15) {
                card("SENSE", "persistent border and maritime awareness", color: cyan, width: 450)
                card("SUSTAIN", "autonomous high-altitude resupply", color: india, width: 450)
                card("DEFEND", "layered counter-drone and EW", color: signal, width: 450)
            }
            .opacity(thesis).offset(x: 560, y: 260)
        }
    }

    // MARK: 09 India foundations

    @MainActor static func indiaFoundations(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let stack = Ease.easeOut(Ease.clip(t, 1.0, 8.0))
        let gap = Ease.easeOutBack(Ease.clip(t, 10.0, 11.2))
        let items = [
            ("DAIC", "defence AI coordination", cyan),
            ("iDEX + ADITI", "innovation and deep-tech funding", signal),
            ("DRDO FLYING WING", "indigenous autonomous demonstrator", amber),
            ("HIM-DRONE-A-THON", "high-altitude trials with users", india),
        ]
        return VStack(alignment: .leading, spacing: 26) {
            eyebrow("INDIA HAS FOUNDATIONS", e, color: india)
            HStack(alignment: .lastTextBaseline) {
                titleText("PROJECTS", size: 92)
                titleText("→", color: grid, size: 62)
                titleText("ECOSYSTEM.", color: india, size: 92)
            }
            HStack(spacing: 30) {
                VStack(spacing: 18) {
                    ForEach(0..<items.count, id: \.self) { i in
                        let p = Ease.easeOut(Ease.clip(stack, Double(i) / 5, Double(i + 2) / 5))
                        HStack(spacing: 20) {
                            titleText(String(format: "%02d", i + 1), color: items[i].2, size: 42)
                            card(items[i].0, items[i].1, color: items[i].2, width: 620)
                        }.opacity(p).offset(x: (1 - p) * -80)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    mono("THE SCALE GAP", color: danger, size: 17)
                    titleText("PROTO", color: dim, size: 66)
                    titleText("→", color: grid, size: 46)
                    titleText("FIELD", color: amber, size: 66)
                    titleText("→", color: grid, size: 46)
                    titleText("FLEET", color: signal, size: 66)
                    mono("procurement · software · production · doctrine", color: ink, size: 13)
                }
                .padding(30).frame(width: 440, height: 470, alignment: .leading)
                .background(panel.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(danger.opacity(0.6)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(gap).opacity(gap)
            }
            HStack(spacing: 10) {
                sourceTag("INDIA MEA / MILITARY AI + LAWS / JAN 2025")
                sourceTag("PIB / DRDO AUTONOMOUS FLYING WING")
                sourceTag("PIB / HIM-DRONE-A-THON-2")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 130)
    }

    // MARK: 10 Five moves

    @MainActor static func fiveMoves(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let items = [
            ("01", "SHARED SOFTWARE LAYER", "connect sensors, commanders, and systems", cyan),
            ("02", "FIELD-DRIVEN TEST LOOPS", "iterate with soldiers in realistic conditions", signal),
            ("03", "DOMESTIC COMPONENTS + SCALE", "secure supply and surge production", india),
            ("04", "EW + COUNTER-DRONE DEPTH", "assume links fail and threats multiply", danger),
            ("05", "HUMAN CONTROL RULES", "accountability designed in from the start", amber),
        ]
        return VStack(alignment: .leading, spacing: 24) {
            eyebrow("FIVE MOVES FOR INDIA", e, color: india)
            HStack(alignment: .lastTextBaseline) {
                titleText("BUILD THE", size: 86)
                titleText("LEARNING SYSTEM.", color: signal, size: 86)
            }
            HStack(alignment: .bottom, spacing: 17) {
                ForEach(0..<items.count, id: \.self) { i in
                    let p = Ease.easeOutBack(Ease.clip(t, 1.0 + Double(i) * 0.7,
                                                       2.5 + Double(i) * 0.7))
                    VStack(alignment: .leading, spacing: 16) {
                        titleText(items[i].0, color: items[i].3, size: 54)
                        Rectangle().fill(items[i].3).frame(width: 55, height: 4)
                        mono(items[i].1, color: ink, size: 16)
                        mono(items[i].2, color: dim, size: 12)
                        Spacer()
                        ForEach(0..<5, id: \.self) { j in
                            Rectangle().fill(j <= i ? items[i].3.opacity(0.8) : grid)
                                .frame(height: 5)
                        }
                    }
                    .padding(22).frame(width: 315, height: CGFloat(350 + i * 55), alignment: .leading)
                    .background(panel.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(items[i].3.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .scaleEffect(y: p, anchor: .bottom).opacity(p)
                }
            }
            mono("STRATEGIC RECOMMENDATION / NOT OPERATIONAL GUIDANCE", color: dim, size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 130)
    }

    // MARK: 11 Finale

    @MainActor static func finale(_ t: Double) -> some View {
        let e = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let people = Ease.easeOutBack(Ease.clip(t, 0.8, 2.2))
        let machines = Ease.easeOut(Ease.clip(t, 2.5, 5.5))
        let final = Ease.easeOut(Ease.clip(t, 7.5, 9.5))
        let underline = Ease.easeInOut(Ease.clip(t, 9.5, 11.0))
        return ZStack {
            imageBackdrop("autonomy-himalaya", opacity: 0.36)
            VStack(alignment: .leading, spacing: 14) {
                eyebrow("THE OBJECTIVE", e, color: india)
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        mono("PEOPLE SET", color: india, size: 17)
                        titleText("INTENT.", color: ink, size: 88)
                        titleText("JUDGMENT.", color: ink, size: 88)
                        titleText("LIMITS.", color: ink, size: 88)
                    }.scaleEffect(people, anchor: .leading).opacity(people)
                    Rectangle().fill(grid).frame(width: 2, height: 430)
                    VStack(alignment: .leading, spacing: 6) {
                        mono("MACHINES EXPAND", color: signal, size: 17)
                        titleText("AWARENESS.", color: signal, size: 72)
                        titleText("ENDURANCE.", color: signal, size: 72)
                        titleText("SCALE.", color: signal, size: 72)
                    }.opacity(machines).offset(x: (1 - machines) * 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 150)
            .offset(y: -80)

            VStack(alignment: .leading, spacing: 8) {
                mono("INDIA SHOULD BUILD", color: india, size: 16)
                titleText("THE ECOSYSTEM THAT", size: 66)
                titleText("LEARNS FASTEST.", color: signal, size: 82)
                Rectangle().fill(india).frame(width: 940 * underline, height: 6)
            }
            .padding(.horizontal, 34).padding(.vertical, 25)
            .background(black.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(signal.opacity(0.55)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(final)
            .offset(y: 375)
        }
    }
}
