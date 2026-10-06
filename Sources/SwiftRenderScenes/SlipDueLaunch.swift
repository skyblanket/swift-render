import SwiftUI
import SwiftRender

/// SlipDueLaunch — "8:47pm Backpack Panic" launch spot for SlipDue, cut for moms.
/// 28s vertical (9:16). Shame → relief arc: night kitchen panic → snap → sign → proof → calm morning → CTA.
///
///   swift run swift-render check SlipDueLaunch
///   swift run swift-render frame SlipDueLaunch --at 1.0,6.5,12.5,18.5,26.0
///   swift run swift-render render SlipDueLaunch --aspect 9:16 --out out/slipdue-28s.mp4
///   swift run swift-render captions SlipDueLaunch --out out/slipdue.srt
public struct SlipDueLaunch: RenderScene {
    public static let defaultDuration: Double = 28.0

    // MARK: - Palette
    static let cream = Color(red: 1.0, green: 0.972, blue: 0.925)
    static let night = Color(red: 0.09, green: 0.08, blue: 0.07)
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let paperRed = Color(red: 1.0, green: 0.231, blue: 0.188)
    static let schoolYellow = Color(red: 1.0, green: 0.839, blue: 0.039)
    static let teal = Color(red: 0.20, green: 0.78, blue: 0.75)
    static let morning = Color(red: 0.96, green: 0.94, blue: 0.88)

    static func hookFont(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static func bodyFont(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }

    // MARK: - Soundtrack (hits on chapter cuts, house rule: no whoosh/riser)
    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            sample("openear-foley/card_3.wav", at: 0.5, amp: 0.4)
            thump(at: 2.0); thump(at: 3.2)
            sample("openear-foley/card_5.wav", at: 3.2, amp: 0.5)
            sample("openear-foley/card_1.wav", at: 6.0, amp: 0.4)
            thump(at: 5.5); rim(at: 8.0); rim(at: 9.2); thump(at: 11.0)
            chordPad(.major7(.f3), at: 11.0, duration: 13.5)
            arpeggio(.major7(.a3), from: 11.0, to: 24.5, step: 0.3)
            fourOnFloor(from: 11.0, to: 24.5, bpm: 100)
            sample("openear-foley/click_1.wav", at: 11.8, amp: 0.5)
            tick(at: 11.8); tick(at: 13.5)
            rim(at: 17.0); tick(at: 17.8); tick(at: 18.6); tick(at: 19.4)
            swell(.major7(.f3), into: 21.5, duration: 1.5)
            crash(at: 24.5)
            boom(at: 27.2)
            speak("It's eight forty-seven, and you just found this at the bottom of the backpack.", at: 0.3)
            speak("Permission slip, lunch money, field trip — still wadded in the lunchbox?", at: 4.5)
            speak("Snap the paper. SlipDue reads it — owe, sign, bring, due.", at: 11.5)
            speak("One tap to sign. Proof saved. No more nine p.m. backpack panic.", at: 17.5)
            speak("You're not a bad mom. You just needed a backpack translator.", at: 24.5)
        }
    }

    static let captions = CaptionTrack(soundtrack(duration: defaultDuration)!)

    // MARK: - Body
    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Timeline(t) {
                Clip(2.0) { l in s1Hook(l) }
                Clip(3.5) { l in s2Chaos(l) }
                Clip(5.5) { l in s3Stamps(l) }
                Clip(6.0) { l in s4Snap(l) }
                    .transition(.slide(0.4, from: .trailing, distance: 1080))
                Clip(4.5) { l in s5Proof(l) }
                    .transition(.slide(0.4, from: .trailing, distance: 1080))
                Clip(3.0) { l in s6Relief(l) }
                    .transition(.fade(0.4))
                Clip(3.5) { l in s7CTA(l) }
                    .transition(.fade(0.4))
                Clip(at: 0, for: duration) { _ in CaptionView(captions, at: t).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90) }
                Clip(at: 0, for: duration) { _ in progressHUDTop(t, total: duration) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - S1 hook 0-2s: night kitchen, crumpled slip to lens
    @ViewBuilder @MainActor static func s1Hook(_ t: Double) -> some View {
        let p1 = Ease.easeOut(Ease.clip(t, 0.1, 0.7))
        let p2 = Ease.easeOut(Ease.clip(t, 0.5, 1.2))
        let flash = 1.0 - Ease.clip(t, 0.0, 0.25)
        ZStack {
            night.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("8:47PM").font(hookFont(120)).foregroundStyle(schoolYellow)
                    .opacity(p1).offset(y: CGFloat(1 - p1) * 60)
                Text("YOU FIND THIS").font(hookFont(64)).foregroundStyle(.white)
                    .opacity(p2).offset(y: CGFloat(1 - p2) * 50)
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(white: 0.92)).frame(width: 420, height: 300)
                        .rotationEffect(.degrees(-8)).shadow(color: .black.opacity(0.6), radius: 24)
                    VStack(spacing: 8) {
                        Text("PERMISSION SLIP").font(bodyFont(40)).foregroundStyle(ink)
                        Text("due TOMORROW").font(hookFont(52)).foregroundStyle(paperRed)
                    }.rotationEffect(.degrees(-8))
                }
                .scaleEffect(1.25 - 0.25 * CGFloat(p2)).padding(.top, 30)
            }
            Color.white.opacity(Double(flash) * 0.55).ignoresSafeArea()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - S2 chaos 2-5.5s: backpack dump, three slips
    @ViewBuilder @MainActor static func s2Chaos(_ t: Double) -> some View {
        ZStack {
            Color(red: 0.16, green: 0.14, blue: 0.12).ignoresSafeArea()
            VStack(spacing: 26) {
                Text("THE BACKPACK").font(hookFont(72)).foregroundStyle(.white)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.0, 0.5)))
                ForEach(0..<3, id: \.self) { i in
                    let p = Ease.easeOut(Ease.clip(t, 0.2 + Double(i) * 0.35, 0.9 + Double(i) * 0.35))
                    let labels = ["FIELD TRIP $12", "SIGN — READING LOG", "BRING — SNACKS FRI"]
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.94)).frame(width: 640, height: 130)
                        .overlay(Text(labels[i]).font(bodyFont(44)).foregroundStyle(ink))
                        .rotationEffect(.degrees([-6, 4, -3][i]))
                        .offset(x: CGFloat(1 - p) * (i % 2 == 0 ? -700 : 700))
                        .opacity(p)
                }
            }.padding(.horizontal, 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - S3 stamps 5.5-11s: OWE / SIGN / BRING / DUE stamps slam
    @ViewBuilder @MainActor static func s3Stamps(_ t: Double) -> some View {
        let stamps = ["OWE $12", "SIGN", "BRING", "DUE TOMORROW"]
        ZStack {
            cream.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("EVERY PAPER = 4 JOBS").font(hookFont(56)).foregroundStyle(ink)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.0, 0.5)))
                ForEach(0..<4, id: \.self) { i in
                    let p = Ease.easeOutBack(Ease.clip(t, 0.3 + Double(i) * 0.55, 0.75 + Double(i) * 0.55))
                    Text(stamps[i]).font(hookFont(i == 3 ? 64 : 84))
                        .foregroundStyle(i == 3 ? paperRed : ink)
                        .padding(.horizontal, 34).padding(.vertical, 10)
                        .background(schoolYellow.cornerRadius(14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(i == 3 ? paperRed : ink, lineWidth: 6))
                        .scaleEffect(max(0.01, CGFloat(p))).opacity(min(1, p + 0.2))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - S4 snap 11-17s: phone scan POV
    @ViewBuilder @MainActor static func s4Snap(_ t: Double) -> some View {
        let inset = 60.0 - 30.0 * Ease.easeOut(Ease.clip(t, 0.5, 1.5))
        let cardP = Ease.easeOut(Ease.clip(t, 1.5, 2.5))
        let typed = Int(Ease.clip(t, 2.2, 4.2) * Double("Reading...".count))
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.95)).frame(width: 520, height: 560)
                    VStack(spacing: 8) {
                        Text("FIELD TRIP").font(bodyFont(40)).foregroundStyle(ink)
                        Text("$12 • FRI").font(hookFont(56)).foregroundStyle(ink)
                    }
                    ScanCorners(inset: inset)
                }
                Text("SNAP THE PAPER").font(hookFont(60)).foregroundStyle(.white)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.0, 0.5)))
                VStack(spacing: 8) {
                    Text("OWE $12 • SIGN • BRING • DUE FRI").font(bodyFont(36)).foregroundStyle(ink)
                    Text(String("Reading...".prefix(typed))).font(bodyFont(32)).foregroundStyle(teal)
                }
                .padding(.horizontal, 22).padding(.vertical, 18).background(Color.white.cornerRadius(20))
                .offset(y: CGFloat(1 - cardP) * 200).opacity(cardP)
                Spacer().frame(height: 150)
            }.padding(.horizontal, 60).padding(.top, 120)
            if t > 0.75 && t < 0.95 { Color.white.opacity(0.7).ignoresSafeArea() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder @MainActor static func ScanCorners(inset: Double) -> some View {
        // 4 explicit L-brackets in a 560x600 box around the 520x560 card.
        // Teal on the dark bg = always visible. `inset` 60->30 converges scale.
        let lock = 1.0 - Ease.easeOut(Ease.clip(inset, 30, 60))
        VStack {
            HStack { Bracket(sx: -1, sy: -1); Spacer(); Bracket(sx: 1, sy: -1) }
            Spacer()
            HStack { Bracket(sx: -1, sy: 1); Spacer(); Bracket(sx: 1, sy: 1) }
        }
        .frame(width: 560, height: 600)
        .scaleEffect(1.12 - 0.12 * CGFloat(lock))
        .opacity(0.6 + 0.4 * Double(lock))
    }

    @MainActor static func Bracket(sx: CGFloat, sy: CGFloat) -> some View {
        let len: CGFloat = 64
        return Path { p in
            if sx < 0 && sy < 0 { p.move(to: CGPoint(x: 0, y: len)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: len, y: 0)) }
            else if sx > 0 && sy < 0 { p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: len, y: 0)); p.addLine(to: CGPoint(x: len, y: len)) }
            else if sx < 0 && sy > 0 { p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: len)); p.addLine(to: CGPoint(x: len, y: len)) }
            else { p.move(to: CGPoint(x: len, y: 0)); p.addLine(to: CGPoint(x: len, y: len)); p.addLine(to: CGPoint(x: 0, y: len)) }
        }.stroke(teal, lineWidth: 10).frame(width: len, height: len)
    }

    // MARK: - S5 proof 17-21.5s: one tap sign, proof saved
    @ViewBuilder @MainActor static func s5Proof(_ t: Double) -> some View {
        let signP = Ease.easeOutBack(Ease.clip(t, 0.4, 1.1))
        let proofP = Ease.easeOut(Ease.clip(t, 1.6, 2.4))
        ZStack {
            cream.ignoresSafeArea()
            VStack(spacing: 30) {
                Text("ONE TAP TO SIGN").font(hookFont(72)).foregroundStyle(ink)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.0, 0.5)))
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(.white).frame(width: 640, height: 260)
                        .shadow(color: .black.opacity(0.15), radius: 20)
                    Text("✓ SIGNED").font(hookFont(90)).foregroundStyle(teal)
                        .scaleEffect(max(0.01, CGFloat(signP)))
                }
                HStack(spacing: 16) {
                    Text("PROOF SAVED ✓").font(bodyFont(40)).foregroundStyle(.white)
                }.padding(.horizontal, 36).padding(.vertical, 16)
                    .background(teal.cornerRadius(18)).opacity(proofP)
                    .offset(y: CGFloat(1 - proofP) * 40)
                Text("Saved automatically — show the teacher.").font(bodyFont(38)).foregroundStyle(ink)
                    .opacity(Ease.easeOut(Ease.clip(t, 2.4, 3.2)))
                Spacer().frame(height: 150)
            }.padding(.horizontal, 50)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - S6 relief 21.5-24.5s: calm morning kitchen
    @ViewBuilder @MainActor static func s6Relief(_ t: Double) -> some View {
        let p = Ease.easeOut(Ease.clip(t, 0.2, 1.2))
        ZStack {
            morning.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("☀️").font(.system(size: 110)).opacity(p)
                Text("CALM MORNINGS").font(hookFont(76)).foregroundStyle(ink)
                    .opacity(p).offset(y: CGFloat(1 - p) * 40)
                Text("Coffee's hot. Backpack's handled.").font(bodyFont(46)).foregroundStyle(ink.opacity(0.7))
                    .opacity(Ease.easeOut(Ease.clip(t, 0.8, 1.8)))
                Spacer().frame(height: 150)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - S7 CTA 24.5-28s: logo + paywall
    @ViewBuilder @MainActor static func s7CTA(_ t: Double) -> some View {
        let p = Ease.easeOut(Ease.clip(t, 0.1, 0.8))
        let btnP = Ease.easeOutBack(Ease.clip(t, 0.8, 1.5))
        ZStack {
            ink.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("SlipDue").font(hookFont(130)).foregroundStyle(.white)
                    .opacity(p).scaleEffect(0.9 + 0.1 * CGFloat(p))
                Text("School slips, signed & due.").font(bodyFont(48)).foregroundStyle(.white.opacity(0.8)).opacity(p)
                Text("FREE 3 SCANS").font(hookFont(56)).foregroundStyle(ink)
                    .padding(.horizontal, 44).padding(.vertical, 16)
                    .background(schoolYellow.cornerRadius(18))
                    .scaleEffect(max(0.01, CGFloat(btnP)))
                Text("$39.99/yr family proof").font(bodyFont(40)).foregroundStyle(.white.opacity(0.85)).opacity(p)
                Text("⬇ Download on the App Store").font(bodyFont(44)).foregroundStyle(teal).opacity(p)
                Spacer().frame(height: 170)
            }.padding(.horizontal, 50)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Progress HUD (top, clear of captions)
    @ViewBuilder @MainActor static func progressHUDTop(_ t: Double, total: Double) -> some View {
        VStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 6)
                    Capsule().fill(schoolYellow).frame(width: max(0, geo.size.width * CGFloat(t / total)), height: 6)
                }
            }.frame(height: 6).padding(.horizontal, 40).padding(.top, 54)
            Spacer()
        }
    }
}
