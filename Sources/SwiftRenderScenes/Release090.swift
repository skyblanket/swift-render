import SwiftUI
import SwiftRender

/// Release090 — a 40-second, narrated tour of what's new in swift-render 0.9.
///
///   swift run swift-render check  Release090
///   swift run swift-render render Release090 --jobs auto --out out/release-0.9.mp4
///
/// Nine 4.5 s sections (two bars at 106⅔ BPM): title · --jobs · frame-exact seams ·
/// smoke · voice vs music · Vision · the scenes target · cleanup · lockup. Every
/// number on screen was measured on this repo. The Vision section draws a
/// synthetic pose through the real `PoseOverlay` + `Stylize` path (no footage of a
/// person ships with the repo) and says so on screen.
public struct Release090: RenderScene {
    public static let defaultDuration: Double = 40.5
    public static var ownsPostFX: Bool { true }

    static let beat: Double = 0.5625
    static let bar: Double = beat * 4
    static let section: Double = bar * 2
    static let W: Double = 1920, H: Double = 1080
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let cream = Color(red: 0.94, green: 0.91, blue: 0.84)
    static let volt = Color(red: 0.78, green: 1.0, blue: 0.10)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.36)

    static let lines: [String] = [
        "Swift render, zero point nine.",
        "Render on every core. Three times faster.",
        "And every seam is frame exact.",
        "Every scene, smoke tested on every push.",
        "It measures the voice you can't hear. Like this one.",
        "Apple Vision, built in. Pose, hands, and a cutout.",
        "The engine stands alone. The demos live next door.",
        "Sixty four megabytes lighter. Not one swish.",
        "Render it.",
    ]

    static let voice: TTSEngine = {
        let python = AssetPaths.packageRoot.appendingPathComponent(".venv-kokoro/bin/python").path
        return FileManager.default.isExecutableFile(atPath: python) ? .kokoro(voice: "af_heart") : .say(voice: "Samantha", wpm: 170)
    }()

    static func start(_ k: Int) -> Double { Double(k) * section }

    // MARK: - Soundtrack (tonal marks only — no sweeps)

    public static func soundtrack(duration: Double) -> Score? {
        var ev: [ScoreEvent] = []
        for (k, line) in lines.enumerated() {
            ev += speak(line, at: start(k) + (k == 0 ? 0.45 : 0.2), engine: voice, amp: 1.4)
        }
        let chords: [Chord] = [.minor9(.a3), .major7(.f3), .add9(.c4), .sus4(.g3), .minor7(.d4),
                               .minor9(.a3), .major7(.f3), .sus4(.g3), .major7(.c4)]
        for (k, ch) in chords.enumerated() {
            ev += chordPad(ch, at: start(k), duration: section + 0.4, amp: 0.012)
            if k > 0 { ev += thump(at: start(k), amp: 0.14) }
        }
        // soft pulse under sections 1–7
        for k in 1..<8 {
            for q in 0..<8 {
                let t: Double = start(k) + Double(q) * beat
                if q % 2 == 0 { ev += kick(at: t, amp: 0.09) }
                ev += hat(at: t + beat / 2, amp: 0.011, pan: q % 2 == 0 ? -0.3 : 0.3)
            }
        }
        // section motifs
        ev += arpeggio(Chord.major7(.f4), from: start(1) + 0.3, to: start(1) + 2.6, step: beat / 4, amp: 0.022, instrument: .chip)
        ev += blip(.c6, at: start(1) + 3.3, amp: 0.05)
        ev += blip(.e5, at: start(2) + 2.0, amp: 0.045); ev += blip(.e5, at: start(2) + 2.2, amp: 0.045)
        for i in stride(from: 0, to: smokeNames.count, by: 3) {
            ev += tick(at: start(3) + 0.4 + Double(i) * 0.06, amp: 0.05, pan: Double(i % 5) * 0.3 - 0.6)
        }
        ev += blip(.g5, at: start(4) + 2.4, amp: 0.045)
        ev += melody([(0, .a4), (1, .c5), (2, .e5), (3, .d5)], start: start(5) + 0.2, bpm: 106.67, amp: 0.035, instrument: .pluck)
        for c in 0..<4 { ev += blip(Scale.majorPentatonic.degree(c * 2, root: .c5), at: start(7) + 0.3 + Double(c) * beat * 2, amp: 0.045) }
        ev += swell(Chord.sus4(.g3), into: start(8), duration: 2.0, amp: 0.02)
        ev += boom(at: start(8), amp: 0.16, duration: 2.0)
        ev += melody([(0, .c5), (0.5, .e5), (1, .g5), (2, .c6)], start: start(8) + 1.4, bpm: 106.67, amp: 0.04, instrument: .bell)
        return Score(duration: duration) { ev }
    }

    static let captions = CaptionTrack(soundtrack(duration: defaultDuration)!, maxChars: 48)

    // MARK: - Body

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        let k: Int = min(8, Int(t / section))
        let l: Double = t - start(k)
        let fadeIn: Double = 1 - Ease.clip(t, 0, 0.35)
        let fadeOut: Double = Ease.easeIn(Ease.clip(t, duration - 0.8, duration))
        let enter: Double = Ease.easeOut(Ease.clip(l, 0, 0.35))
        let leave: Double = Ease.easeIn(Ease.clip(l, section - 0.25, section))
        return ZStack {
            bg
            section(k, l, t)
                .opacity(k == 8 ? enter : enter * (1 - leave))
                .offset(y: (1 - enter) * 26)
            if k > 0 && k < 8 { chapter(k) }
            CaptionView(captions, at: t, style: .karaoke,
                        font: .system(size: 40, weight: .semibold), color: cream, highlight: volt, plate: true)
                .frame(width: 1600)
                .position(x: W / 2, y: 985)
            Color.black.opacity(max(fadeIn, fadeOut))
        }
        .frame(width: W, height: H)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
    }

    @MainActor
    static func section(_ k: Int, _ l: Double, _ t: Double) -> AnyView {
        switch k {
        case 0: return AnyView(title(l))
        case 1: return AnyView(jobs(l))
        case 2: return AnyView(seams(l))
        case 3: return AnyView(smoke(l))
        case 4: return AnyView(voiceLevels(l))
        case 5: return AnyView(vision(l, t))
        case 6: return AnyView(targets(l))
        case 7: return AnyView(cleanup(l))
        default: return AnyView(lockup(l, t))
        }
    }

    static func mono(_ s: Double, _ w: Font.Weight = .medium) -> Font { .system(size: s, weight: w, design: .monospaced) }
    static func heavy(_ s: Double) -> Font { .system(size: s, weight: .black).width(.condensed) }

    @ViewBuilder @MainActor
    static func chapter(_ k: Int) -> some View {
        let names: [String] = ["", "--jobs", "frame-exact", "smoke", "voice vs music", "VisionTrack",
                               "SwiftRenderScenes", "cleanup"]
        HStack(spacing: 14) {
            Text(String(format: "%02d", k)).foregroundStyle(volt)
            Text(names[k]).foregroundStyle(cream.opacity(0.75))
        }
        .font(mono(24, .semibold))
        .frame(width: W, height: H, alignment: .topLeading)
        .offset(x: 70, y: 60)
    }

    @ViewBuilder @MainActor
    static func headline(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(big).font(heavy(120)).foregroundStyle(cream)
            Text(small).font(mono(28)).foregroundStyle(cream.opacity(0.6))
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .offset(x: 70, y: 130)
    }

    // MARK: 0 · title

    @ViewBuilder @MainActor
    static func title(_ l: Double) -> some View {
        let pop: Double = Ease.spring(max(0, l - 0.35), from: 1.6, to: 1.0, response: 0.32, dampingFraction: 0.62)
        let sub: Double = Ease.easeOut(Ease.clip(l, 1.0, 1.5))
        VStack(spacing: -10) {
            Text("swift-render").font(mono(44, .semibold)).foregroundStyle(cream.opacity(0.75)).opacity(sub)
            Text("0.9").font(heavy(420)).foregroundStyle(volt)
                .scaleEffect(pop).opacity(l > 0.35 ? 1 : 0)
            Text("parallel renders · Apple Vision · a mix you can measure")
                .font(mono(30)).foregroundStyle(cream.opacity(0.7)).opacity(sub)
        }
        .position(x: W / 2, y: 470)
    }

    // MARK: 1 · --jobs

    @MainActor
    static func jobs(_ l: Double) -> some View {
        Canvas { ctx, _ in
            let x0: Double = 160, wBar: Double = 1600
            ctx.draw(Text("render StyleLab  ·  41 s of 1080p60  ·  2,475 frames").font(mono(28)).foregroundColor(cream.opacity(0.6)),
                     at: CGPoint(x: x0, y: 200), anchor: .leading)
            // one process
            let solo: Double = Ease.clip(l, 0.2, 4.4) * (19.0 / 65.0) * 1.05
            ctx.draw(Text("1 process").font(mono(26, .semibold)).foregroundColor(cream.opacity(0.7)),
                     at: CGPoint(x: x0, y: 300), anchor: .leading)
            ctx.fill(Path(roundedRect: CGRect(x: x0, y: 330, width: wBar, height: 34), cornerRadius: 8), with: .color(cream.opacity(0.1)))
            ctx.fill(Path(roundedRect: CGRect(x: x0, y: 330, width: wBar * solo, height: 34), cornerRadius: 8), with: .color(cream.opacity(0.55)))
            // five processes
            ctx.draw(Text("--jobs 5").font(mono(26, .semibold)).foregroundColor(volt),
                     at: CGPoint(x: x0, y: 440), anchor: .leading)
            let merge: Double = Ease.easeInOut(Ease.clip(l, 2.5, 3.2))
            let chunkW: Double = wBar / 5
            for c in 0..<5 {
                let fill: Double = Ease.clip(l, 0.3 + Double(c) * 0.04, 2.4 + Double(c) * 0.04)
                let laneY: Double = 470 + Double(c) * 44
                let y: Double = laneY + (470 - laneY) * merge
                let x: Double = x0 + Double(c) * chunkW
                ctx.fill(Path(roundedRect: CGRect(x: x + 2, y: y, width: chunkW - 4, height: 34), cornerRadius: 8), with: .color(cream.opacity(0.1)))
                ctx.fill(Path(roundedRect: CGRect(x: x + 2, y: y, width: (chunkW - 4) * fill, height: 34), cornerRadius: 8), with: .color(volt))
            }
            let stat: Double = Ease.easeOut(Ease.clip(l, 3.0, 3.5))
            var c2 = ctx
            c2.opacity = stat
            c2.draw(Text("65 s  →  19 s").font(heavy(110)).foregroundColor(cream), at: CGPoint(x: x0, y: 790), anchor: .leading)
            c2.draw(Text("stitched without re-encoding").font(mono(28)).foregroundColor(volt), at: CGPoint(x: x0 + 760, y: 800), anchor: .leading)
        }
        .frame(width: W, height: H)
    }

    // MARK: 2 · frame-exact seams

    @MainActor
    static func seams(_ l: Double) -> some View {
        Canvas { ctx, _ in
            let frames: [Int] = Array(491...499)
            let cw: Double = 168, x0: Double = W / 2 - cw * Double(frames.count) / 2
            let rows: [(String, Double)] = [("single process", 360), ("--jobs 5, stitched", 560)]
            let slide: Double = Ease.easeOut(Ease.clip(l, 0.2, 1.4))
            for (r, row) in rows.enumerated() {
                ctx.draw(Text(row.0).font(mono(24, .semibold)).foregroundColor(r == 0 ? cream.opacity(0.7) : volt),
                         at: CGPoint(x: x0, y: row.1 - 40), anchor: .leading)
                for (i, f) in frames.enumerated() {
                    let off: Double = r == 1 ? (f >= 495 ? 1 : -1) * 120 * (1 - slide) : 0
                    let rect = CGRect(x: x0 + Double(i) * cw + off + 6, y: row.1, width: cw - 12, height: 110)
                    let shade: Double = 0.2 + 0.5 * (0.5 + 0.5 * sin(Double(f) * 0.9))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(cream.opacity(shade * 0.35)))
                    ctx.draw(Text("\(f)").font(mono(30, .semibold)).foregroundColor(cream),
                             at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                }
            }
            let seamX: Double = x0 + 4 * cw
            var seam = Path(); seam.move(to: CGPoint(x: seamX, y: 300)); seam.addLine(to: CGPoint(x: seamX, y: 700))
            ctx.stroke(seam, with: .color(volt.opacity(Ease.clip(l, 1.2, 1.5))), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            let ok: Double = Ease.easeOut(Ease.clip(l, 1.9, 2.4))
            var c2 = ctx
            c2.opacity = ok
            c2.draw(Text("chunk seam  ·  frame 495 = frame 495").font(mono(30, .semibold)).foregroundColor(volt),
                    at: CGPoint(x: W / 2, y: 780), anchor: .center)
            c2.draw(Text("absolute frame times · no B-frames · first frame at t = 0").font(mono(26)).foregroundColor(cream.opacity(0.6)),
                    at: CGPoint(x: W / 2, y: 830), anchor: .center)
        }
        .frame(width: W, height: H)
    }

    // MARK: 3 · smoke

    static let smokeNames: [String] = [
        "AudioBars", "AutonomousWar", "BillionDollars", "BugTest", "CardStack", "DahliaProcessing", "FilmScore62",
        "FilmScoreSC", "FutureOfTheFirm", "IGCaption", "IGHook", "IGOutro", "JustRenderIt", "Kinetic", "KineticType", "LaunchFilm",
        "LaunchFilm2", "LaunchReel", "LogoReveal", "MediaDemo", "NeverHeard", "NotchRecording", "OpenEarLaunch",
        "OriginsOfWokeness", "ParticleField", "PixelSonnet", "Release090", "RepoPromo", "Rotoscope", "ShaderGallery",
        "ShaderShowcase", "Sizzle", "SlipDueLaunch", "SpiderNoir", "StyleLab", "StyleReel", "StyleReelVertical",
        "SwarmRTFilm", "SwarmRTPromo", "TextReveal", "TimelineDemo", "VinylSpin", "WaveformDance", "WelcomeSplash",
    ]

    @MainActor
    static func smoke(_ l: Double) -> some View {
        Canvas { ctx, _ in
            ctx.draw(Text("$ swift-render smoke").font(mono(28)).foregroundColor(cream.opacity(0.6)),
                     at: CGPoint(x: 160, y: 190), anchor: .leading)
            let cols: Int = 4
            for (i, name) in smokeNames.enumerated() {
                let shown: Double = Ease.clip(l, 0.4 + Double(i) * 0.06, 0.5 + Double(i) * 0.06)
                if shown <= 0 { continue }
                let x: Double = 160 + Double(i % cols) * 410, y: Double = 250 + Double(i / cols) * 46
                var c2 = ctx
                c2.opacity = shown
                c2.draw(Text("ok").font(mono(22, .bold)).foregroundColor(volt), at: CGPoint(x: x, y: y), anchor: .leading)
                c2.draw(Text(name).font(mono(22)).foregroundColor(cream.opacity(0.8)), at: CGPoint(x: x + 46, y: y), anchor: .leading)
            }
            let done: Double = Ease.easeOut(Ease.clip(l, 3.3, 3.7))
            var c3 = ctx
            c3.opacity = done
            c3.draw(Text("44 scenes · 0.6 s · 0 failures · 0 swishes  —  runs in CI").font(mono(28, .semibold)).foregroundColor(volt),
                    at: CGPoint(x: 160, y: 820), anchor: .leading)
        }
        .frame(width: W, height: H)
    }

    // MARK: 4 · voice vs music

    @MainActor
    static func voiceLevels(_ l: Double) -> some View {
        Canvas { ctx, _ in
            ctx.draw(Text("$ swift-render check SlipDueLaunch").font(mono(28)).foregroundColor(cream.opacity(0.6)),
                     at: CGPoint(x: 160, y: 190), anchor: .leading)
            let rows: [(String, Double, Double, Color)] = [
                ("before", -5.8, 0.4, coral), ("after", 14.8, 1.6, volt), ("this video", 13.6, 2.6, cream),
            ]
            let zero: Double = 760, perDB: Double = 32
            var axis = Path(); axis.move(to: CGPoint(x: zero, y: 270)); axis.addLine(to: CGPoint(x: zero, y: 700))
            ctx.stroke(axis, with: .color(cream.opacity(0.35)), lineWidth: 2)
            ctx.draw(Text("music").font(mono(22)).foregroundColor(cream.opacity(0.5)), at: CGPoint(x: zero, y: 720), anchor: .center)
            var six = Path(); six.move(to: CGPoint(x: zero + 6 * perDB, y: 270)); six.addLine(to: CGPoint(x: zero + 6 * perDB, y: 700))
            ctx.stroke(six, with: .color(volt.opacity(0.35)), style: StrokeStyle(lineWidth: 2, dash: [6, 8]))
            ctx.draw(Text("+6 dB").font(mono(20)).foregroundColor(volt.opacity(0.6)), at: CGPoint(x: zero + 6 * perDB, y: 720), anchor: .center)
            for (r, row) in rows.enumerated() {
                let grow: Double = Ease.easeOut(Ease.clip(l, row.2, row.2 + 0.6))
                if grow <= 0 { continue }
                let y: Double = 320 + Double(r) * 130
                let w: Double = row.1 * perDB * grow
                let rect = w >= 0 ? CGRect(x: zero, y: y, width: w, height: 56) : CGRect(x: zero + w, y: y, width: -w, height: 56)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(row.3))
                ctx.draw(Text(row.0).font(mono(26, .semibold)).foregroundColor(cream.opacity(0.75)),
                         at: CGPoint(x: 160, y: y + 28), anchor: .leading)
                ctx.draw(Text(String(format: "voice %+.1f dB", row.1 * grow)).font(mono(26, .bold)).foregroundColor(row.3),
                         at: CGPoint(x: row.1 >= 0 ? zero + w + 20 : zero + 20, y: y + 28), anchor: .leading)
            }
        }
        .frame(width: W, height: H)
    }

    // MARK: 5 · Vision (synthetic pose through the real PoseOverlay + Stylize path)

    static func pose(_ t: Double) -> VisionFrame {
        let s: Double = sin(t * 3.4), c: Double = cos(t * 3.4)
        func p(_ x: Double, _ y: Double) -> VisionPoint { VisionPoint(x: x, y: y, confidence: 0.9) }
        let hip: Double = 0.62 + 0.012 * c
        let body: [String: VisionPoint] = [
            "nose": p(0.5 + 0.01 * s, 0.24), "leftEye": p(0.488, 0.225), "rightEye": p(0.512, 0.225),
            "leftEar": p(0.475, 0.235), "rightEar": p(0.525, 0.235), "neck": p(0.5, 0.31),
            "leftShoulder": p(0.455, 0.33), "rightShoulder": p(0.545, 0.33),
            "leftElbow": p(0.405 - 0.02 * s, 0.39 - 0.07 * s), "rightElbow": p(0.595 + 0.02 * c, 0.39 - 0.07 * c),
            "leftWrist": p(0.37 - 0.05 * s, 0.33 - 0.17 * s), "rightWrist": p(0.63 + 0.05 * c, 0.33 - 0.17 * c),
            "root": p(0.5, hip), "leftHip": p(0.475, hip), "rightHip": p(0.525, hip),
            "leftKnee": p(0.465 - 0.02 * s, 0.75), "rightKnee": p(0.535 + 0.02 * s, 0.75),
            "leftAnkle": p(0.46, 0.88), "rightAnkle": p(0.54, 0.88),
        ]
        return VisionFrame(time: t, body: body)
    }

    @ViewBuilder @MainActor
    static func vision(_ l: Double, _ t: Double) -> some View {
        let figure = Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let f = pose(t)
            var limbs = Path()
            for (a, b) in VisionTrack.bones {
                guard let p = f.body[a], let q = f.body[b] else { continue }
                limbs.move(to: p.at(size)); limbs.addLine(to: q.at(size))
            }
            ctx.stroke(limbs, with: .color(.white), style: StrokeStyle(lineWidth: Double(size.height) * 0.07, lineCap: .round, lineJoin: .round))
            if let n = f.body["nose"] {
                let c = n.at(size), r: Double = Double(size.height) * 0.06
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white))
            }
        }
        let size = CGSize(width: 1100, height: 760)
        let grid = PixelGrid.sample(figure, size: size, cols: 220) ?? PixelGrid(cols: 1, rows: 1, data: [0, 0, 0, 255])
        HStack(alignment: .center, spacing: 60) {
            ZStack {
                Stylize.view(.ascii, grid: grid, size: size, density: 0.8, t: t)
                trails(t, size)
                PoseOverlay(pose(t), color: volt, lineWidth: 4)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 18) {
                Text("VisionTrack.load(\"you.mov\")").font(mono(28, .semibold)).foregroundStyle(volt)
                Text("body · 19 joints\nhands · 21 joints each\nperson mask per frame\nanalyzed once, cached")
                    .font(mono(28)).foregroundStyle(cream.opacity(0.85)).lineSpacing(8)
                Text("Rotoscope: cut out, restyle,\ntrace the skeleton").font(mono(24)).foregroundStyle(cream.opacity(0.6))
                Text("pose here is synthetic data drawn\nthrough PoseOverlay + Stylize")
                    .font(mono(18)).foregroundStyle(cream.opacity(0.4)).padding(.top, 20)
            }
            .opacity(Ease.easeOut(Ease.clip(l, 0.6, 1.1)))
        }
        .position(x: W / 2, y: 520)
    }

    @MainActor
    static func trails(_ t: Double, _ size: CGSize) -> some View {
        Canvas { ctx, sz in
            for joint in ["leftWrist", "rightWrist"] {
                for k in 0..<16 {
                    guard let p = pose(t - Double(k) * 0.03).body[joint], let q = pose(t - Double(k + 1) * 0.03).body[joint] else { continue }
                    var seg = Path(); seg.move(to: p.at(sz)); seg.addLine(to: q.at(sz))
                    let fade: Double = 1 - Double(k) / 16
                    ctx.stroke(seg, with: .color(volt.opacity(0.8 * fade)), style: StrokeStyle(lineWidth: 14 * fade + 2, lineCap: .round))
                }
            }
        }
    }

    // MARK: 6 · SwiftRenderScenes

    @MainActor
    static func targets(_ l: Double) -> some View {
        Canvas { ctx, _ in
            let left = CGRect(x: 220, y: 300, width: 560, height: 360), right = CGRect(x: 1140, y: 300, width: 560, height: 360)
            ctx.stroke(Path(roundedRect: left, cornerRadius: 24), with: .color(cream.opacity(0.7)), lineWidth: 3)
            ctx.stroke(Path(roundedRect: right, cornerRadius: 24), with: .color(volt.opacity(Ease.clip(l, 0.4, 0.9))), lineWidth: 3)
            ctx.draw(Text("SwiftRender").font(heavy(64)).foregroundColor(cream), at: CGPoint(x: left.midX, y: left.minY - 50), anchor: .center)
            ctx.draw(Text("SwiftRenderScenes").font(heavy(64)).foregroundColor(volt.opacity(Ease.clip(l, 0.4, 0.9))),
                     at: CGPoint(x: right.midX, y: right.minY - 50), anchor: .center)
            ctx.draw(Text("engine · components · audio · vision").font(mono(22)).foregroundColor(cream.opacity(0.55)),
                     at: CGPoint(x: left.midX, y: left.maxY + 40), anchor: .center)
            ctx.draw(Text("44 demo scenes, auto-registered").font(mono(22)).foregroundColor(cream.opacity(0.55 * Ease.clip(l, 0.4, 0.9))),
                     at: CGPoint(x: right.midX, y: right.maxY + 40), anchor: .center)
            for i in 0..<44 {
                let col: Int = i % 9, row: Int = i / 9
                let home = CGPoint(x: left.minX + 50 + Double(col) * 57, y: left.minY + 60 + Double(row) * 60)
                let away = CGPoint(x: right.minX + 50 + Double(col) * 57, y: right.minY + 60 + Double(row) * 60)
                let move: Double = Ease.easeInOut(Ease.clip(l, 0.8 + Double(i) * 0.03, 1.6 + Double(i) * 0.03))
                let x: Double = home.x + (away.x - home.x) * move
                let y: Double = home.y + (away.y - home.y) * move - sin(move * Double.pi) * 80
                ctx.fill(Path(roundedRect: CGRect(x: x - 20, y: y - 20, width: 40, height: 40), cornerRadius: 8),
                         with: .color(move > 0.98 ? volt : cream.opacity(0.75)))
            }
            let code: Double = Ease.easeOut(Ease.clip(l, 2.9, 3.3))
            var c2 = ctx
            c2.opacity = code
            c2.draw(Text("import SwiftRender   // engine only — the demos don't compile into your app").font(mono(28)).foregroundColor(cream),
                    at: CGPoint(x: W / 2, y: 820), anchor: .center)
        }
        .frame(width: W, height: H)
    }

    // MARK: 7 · cleanup

    @ViewBuilder @MainActor
    static func cleanup(_ l: Double) -> some View {
        let cards: [(String, String)] = [
            ("−64 MB", "JETRAY scenes + 480 frames removed"),
            ("0 re-encodes", "the audio mux copies the video"),
            ("0 B-frames", "frame 0 sits at t = 0"),
            ("0 swishes", "across 44 scenes · deprecated"),
        ]
        HStack(spacing: 28) {
            ForEach(0..<4, id: \.self) { i in
                let p: Double = Ease.spring(max(0, l - 0.3 - Double(i) * beat * 2), from: 0, to: 1, response: 0.4, dampingFraction: 0.72)
                VStack(alignment: .leading, spacing: 18) {
                    Text(cards[i].0).font(heavy(68)).foregroundStyle(volt)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(cards[i].1).font(mono(22)).foregroundStyle(cream.opacity(0.75))
                }
                .padding(32)
                .frame(width: 400, height: 300, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(cream.opacity(0.25), lineWidth: 2))
                .scaleEffect(0.85 + 0.15 * p)
                .opacity(l > 0.3 + Double(i) * beat * 2 ? min(1, p * 1.4) : 0)
            }
        }
        .position(x: W / 2, y: 500)
    }

    // MARK: 8 · lockup

    @ViewBuilder @MainActor
    static func lockup(_ l: Double, _ t: Double) -> some View {
        let pop: Double = Ease.spring(l, from: 1.25, to: 1.0, response: 0.4, dampingFraction: 0.65)
        let cmd: String = "swift run swift-render render MyFilm --jobs auto"
        let typed: Int = Int(Ease.clip(l, 0.9, 2.6) * Double(cmd.count))
        VStack(spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text("swift-render").font(heavy(190)).foregroundStyle(cream)
                Text("0.9").font(heavy(190)).foregroundStyle(volt)
            }
            .scaleEffect(pop)
            Text(String(cmd.prefix(typed)) + (Int(t * 3) % 2 == 0 ? "▌" : " "))
                .font(mono(34)).foregroundStyle(cream.opacity(0.85))
                .frame(width: 1100, alignment: .leading)
            Text("github.com/skyblanket/swift-render").font(mono(26)).foregroundStyle(cream.opacity(0.5))
                .opacity(Ease.easeOut(Ease.clip(l, 2.6, 3.0)))
        }
        .position(x: W / 2, y: 440)
    }
}
