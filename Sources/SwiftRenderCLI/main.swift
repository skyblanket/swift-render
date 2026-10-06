import AppKit
import AVFoundation
import Foundation
import SwiftRender
import SwiftUI

let swiftRenderVersion = "0.9.0"

// MARK: - Scene registry
//
// Generated at build time by SceneRegistryPlugin: every `public struct X` in the
// SwiftRender target that conforms to a scene protocol is registered as "X".

let sceneRunners: [String: SceneRunner] = generatedSceneRunners

enum AudioSource {
    case none
    case file(URL)
    case score(Score)
}

/// Resolves an AudioSource into (AudioTrack for reactive scenes, mux URL).
/// Scores synthesize once: samples analyzed in memory, temp WAV only for mux.
struct AudioPlan {
    let track: AudioTrack
    let muxURL: URL?
    private let tempURL: URL?

    func cleanup() { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }

    static func make(_ source: AudioSource, fps: Int,
                     needsTrack: Bool, needsMux: Bool) throws -> AudioPlan {
        switch source {
        case .none:
            return AudioPlan(track: .silent, muxURL: nil, tempURL: nil)
        case .file(let url):
            let track = needsTrack ? try AudioAnalyzer.analyze(url: url, fps: fps) : .silent
            return AudioPlan(track: track, muxURL: needsMux ? url : nil, tempURL: nil)
        case .score(let score):
            guard needsTrack || needsMux else {
                return AudioPlan(track: .silent, muxURL: nil, tempURL: nil)
            }
            let (l, r) = ScoreSynth.render(score)
            var track = AudioTrack.silent
            if needsTrack {
                var mono = [Float](repeating: 0, count: l.count)
                for i in 0..<l.count { mono[i] = (l[i] + r[i]) * 0.5 }
                track = try AudioAnalyzer.analyze(samples: mono, sampleRate: scoreSampleRate, fps: fps)
            }
            guard needsMux else { return AudioPlan(track: track, muxURL: nil, tempURL: nil) }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("sr-score-\(UUID().uuidString).wav")
            try WAV.write(left: l, right: r, to: tmp)
            return AudioPlan(track: track, muxURL: tmp, tempURL: tmp)
        }
    }
}

@MainActor
struct SceneRunner {
    let defaultDuration: Double
    /// Pretty-printed default-props JSON; nil for prop-less scenes.
    let propsTemplate: (() -> String)?
    /// Scene-declared soundtrack, if any (duration-aware).
    let soundtrack: (Double) -> Score?
    /// (recorder, outURL, startTime, endTime, sceneDuration, audioSource, mux, propsURL)
    /// `mux: false` renders picture only (range chunks) but still feeds audio-reactive scenes.
    let render: (Recorder, URL, Double, Double, Double, AudioSource, Bool, URL?) async throws -> Void
    /// (recorder, outURL, t, duration, audioSource, propsURL)
    let frame: (Recorder, URL, Double, Double, AudioSource, URL?) throws -> Void
    let ownsPostFX: Bool
    /// (duration, audioSource, propsURL) → a time → view function (live preview).
    let makeView: (Double, AudioSource, URL?) throws -> (Double) -> AnyView

    init<S: RenderScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = nil
        soundtrack = { S.soundtrack(duration: $0) }
        render = { recorder, out, start, end, dur, source, mux, _ in
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: false, needsMux: mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: end, startTime: start, sceneDuration: dur, audioURL: plan.muxURL, postFX: !S.ownsPostFX) { t in
                S.body(at: t, duration: dur)
            }
        }
        frame = { recorder, out, t, dur, _, _ in
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, _, _ in { t in AnyView(S.body(at: t, duration: dur)) } }
    }

    init<S: AudioReactiveScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = nil
        soundtrack = { S.soundtrack(duration: $0) }
        render = { recorder, out, start, end, dur, source, mux, _ in
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: end, startTime: start, sceneDuration: dur, audioURL: plan.muxURL, postFX: !S.ownsPostFX) { t in
                S.body(at: t, duration: dur, audio: plan.track)
            }
        }
        frame = { recorder, out, t, dur, source, _ in
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: false)
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur, audio: plan.track)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, source, _ in
            let plan = try AudioPlan.make(source, fps: 60, needsTrack: true, needsMux: false)
            return { t in AnyView(S.body(at: t, duration: dur, audio: plan.track)) }
        }
    }

    init<S: PropsScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = { Self.templateJSON(S.defaultProps) }
        soundtrack = { S.soundtrack(duration: $0) }
        render = { recorder, out, start, end, dur, source, mux, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: false, needsMux: mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: end, startTime: start, sceneDuration: dur, audioURL: plan.muxURL, postFX: !S.ownsPostFX) { t in
                S.body(at: t, duration: dur, props: props)
            }
        }
        frame = { recorder, out, t, dur, _, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur, props: props)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, _, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            return { t in AnyView(S.body(at: t, duration: dur, props: props)) }
        }
    }

    init<S: PropsAudioScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = { Self.templateJSON(S.defaultProps) }
        soundtrack = { S.soundtrack(duration: $0) }
        render = { recorder, out, start, end, dur, source, mux, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: mux)
            defer { plan.cleanup() }
            try await recorder.render(to: out, duration: end, startTime: start, sceneDuration: dur, audioURL: plan.muxURL, postFX: !S.ownsPostFX) { t in
                S.body(at: t, duration: dur, props: props, audio: plan.track)
            }
        }
        frame = { recorder, out, t, dur, source, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: recorder.config.fps, needsTrack: true, needsMux: false)
            try recorder.renderPNG(at: t, to: out, postFX: !S.ownsPostFX, duration: dur) { tt in
                S.body(at: tt, duration: dur, props: props, audio: plan.track)
            }
        }
        ownsPostFX = S.ownsPostFX
        makeView = { dur, source, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let plan = try AudioPlan.make(source, fps: 60, needsTrack: true, needsMux: false)
            return { t in AnyView(S.body(at: t, duration: dur, props: props, audio: plan.track)) }
        }
    }

    private static func loadProps<P: Codable>(_: P.Type, defaults: P, from url: URL?) throws -> P {
        guard let url else { return defaults }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw PropsError.unreadable(url, error.localizedDescription) }
        do { return try JSONDecoder().decode(P.self, from: data) }
        catch let e as DecodingError { throw PropsError.decode(url, describe(e)) }
    }

    private static func templateJSON<P: Codable>(_ value: P) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String { c.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let ctx): return "missing key '\(k.stringValue)' at \(path(ctx.codingPath))"
        case .typeMismatch(let t, let ctx): return "expected \(t) at \(path(ctx.codingPath))"
        case .valueNotFound(let t, let ctx): return "null for \(t) at \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx): return "invalid JSON: \(ctx.debugDescription)"
        @unknown default: return String(describing: e)
        }
    }
}

enum PropsError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case decode(URL, String)
    var description: String {
        switch self {
        case .unreadable(let u, let why): return "cannot read props \(u.path): \(why)"
        case .decode(let u, let why):     return "props decode failed for \(u.path): \(why)"
        }
    }
}

// MARK: - CLI

struct CLIArgs {
    var subcommand: String          // render | list | preview
    var sceneName: String = ""
    var duration: Double? = nil     // nil → use scene default
    var fps: Int = 60
    var aspect: AspectPreset = .landscape16x9
    var size: CGSize? = nil
    var scale: CGFloat = 1.0
    var out: String = "out/render.mp4"
    var audio: String? = nil
    var at: [Double] = [0]      // `frame` subcommand: one or more timestamps
    var preview = false
    var jobs = 1
    var open = false
    var kind = "render"         // `new`: render | audio
    var rangeStart: Double? = nil
    var rangeEnd: Double? = nil
    var props: String? = nil
    var postFX: Bool = true
    var cols: Int = 5
    var rows: Int = 3
    var snapshot: String? = nil     // `preview`: write the window to PNG after layout, then exit
}

func parseArgs(_ argv: [String]) -> CLIArgs {
    if argv.count < 2 {
        printUsage()
        exit(1)
    }

    let sub = argv[1]
    var args = CLIArgs(subcommand: sub)

    if sub == "list" || sub == "smoke" || sub == "--help" || sub == "-h" || sub == "--version" {
        return args
    }

    guard argv.count >= 3 else {
        fputs("Missing scene name. Try: swift-render list\n", stderr)
        exit(1)
    }
    args.sceneName = argv[2]

    var i = 3
    while i < argv.count {
        let k = argv[i]
        let v = i + 1 < argv.count ? argv[i + 1] : ""
        switch k {
        case "--duration": args.duration = Double(v); i += 2
        case "--fps":      args.fps = Int(v) ?? args.fps; i += 2
        case "--aspect":   args.aspect = AspectPreset(rawValue: v) ?? args.aspect; i += 2
        case "--width":
            let w = max(16, Int(v) ?? 0)
            let curH = Int(args.size?.height ?? 1080)
            args.size = CGSize(width: w, height: curH)
            i += 2
        case "--height":
            let h = max(16, Int(v) ?? 0)
            let curW = Int(args.size?.width ?? 1920)
            args.size = CGSize(width: curW, height: h)
            i += 2
        case "--scale":    args.scale = CGFloat(Double(v) ?? Double(args.scale)); i += 2
        case "--out":      args.out = v; i += 2
        case "--audio":    args.audio = v; i += 2
        case "--at":
            let ts = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            args.at = ts.isEmpty ? [0] : ts; i += 2
        case "--preview":  args.preview = true; i += 1
        case "--jobs":     args.jobs = resolveJobs(v); i += 2
        case "--open":     args.open = true; i += 1
        case "--kind":     args.kind = v; i += 2
        case "--props":    args.props = v; i += 2
        case "--no-postfx": args.postFX = false; i += 1
        case "--cols":     args.cols = max(1, Int(v) ?? 5); i += 2
        case "--rows":     args.rows = max(1, Int(v) ?? 3); i += 2
        case "--snapshot": args.snapshot = v; i += 2
        case "--range":
            let parts = v.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { args.rangeStart = parts[0]; args.rangeEnd = parts[1] }
            i += 2
        default:
            fputs("Unknown option: \(k)\n\n", stderr)
            printUsage()
            exit(64)
        }
    }
    return args
}

func printUsage() {
    fputs("""
    swift-render — programmatic motion graphics in Swift

    USAGE:
      swift-render new <Scene> [--kind audio]  Scaffold Sources/SwiftRenderScenes/<Scene>.swift
      swift-render check <Scene>            Contact sheet + blank-frame scan + audio report
      swift-render preview <Scene>          Live window: scrub, play/pause, frame-step, audio
      swift-render render <Scene> [opts]    Render a scene to MP4
      swift-render frame <Scene> --at <t>   Render frame(s) to PNG; --at 1,2.5,4 for several
      swift-render props <Scene>            Print a scene's default props as JSON
      swift-render contact <Scene>           Render a grid contact sheet to PNG
      swift-render audio <Scene> --out x.wav Export a scene's Score as WAV
      swift-render captions <Scene> --out x.srt  Export voiceover captions (.srt or .vtt)
      swift-render smoke                    Render one frame of every scene; fail on errors or swishes (CI)
      swift-render list                     List available scenes
      swift-render --help                   Show this help
      swift-render --version                Print version

    SCENE OPTIONS:
      --duration <seconds>     Override scene's default duration
      --fps <n>                Frame rate (default 60)
      --aspect 16:9|9:16|1:1   Output aspect (default 16:9)
      --width <px>             Custom width (overrides --aspect)
      --height <px>            Custom height
      --scale <n>              Display scale (default 1.0)
      --out <path>             Output mp4 path (default out/render.mp4)
      --audio <path>           Optional audio file to mux into the output
      --range <a:b>            Render only seconds a..b (picture only; timing matches the full render)
      --at <t>                 Frame timestamp for the `frame` subcommand
      --props <file.json>      JSON props for parameterized scenes
      --cols/--rows <n>        Contact sheet grid (default 5×3)
      --no-postfx              Disable the global grain+vignette pass
      --jobs <n|auto>          Render in n parallel processes and stitch (auto = half the cores)
      --preview                Half resolution, 30 fps — fast look at motion
      --open                   Open the result when done
      --snapshot <png>         `preview` only: save the window to PNG and exit (CI/agents)

    PREVIEW KEYS:
      space play/pause · ←/→ one frame · ⇧←/⇧→ one second · home start · esc/⌘W close

    LOOP:
      swift-render new MyFilm && swift-render check MyFilm
      swift-render preview MyFilm
      swift-render render MyFilm --preview --open
      swift-render render MyFilm --out out/myfilm.mp4

    EXAMPLES:
      swift-render render LogoReveal --out out/hero.mp4
      swift-render render LaunchReel --aspect 16:9 --out out/reel.mp4
      swift-render render NotchRecording --aspect 9:16 --out out/notch-vert.mp4
      swift-render render LogoReveal --audio music/intro.m4a --out out/hero-audio.mp4

    """, stderr)
}

// MARK: - Run

@MainActor
func run() async throws {
    registerBundledFonts()
    let args = parseArgs(CommandLine.arguments)

    switch args.subcommand {
    case "list":
        let names = sceneRunners.keys.sorted()
        for name in names {
            let runner = sceneRunners[name]!
            print("  \(name)  (default: \(runner.defaultDuration)s)")
        }
        return
    case "--help", "-h":
        printUsage()
        return
    case "--version":
        print(swiftRenderVersion)
        return
    case "smoke":
        warnIfShadersStale()
        if !runSmoke(scale: 0.2) { exit(1) }
        return
    case "new":
        do {
            let url = try scaffoldScene(name: args.sceneName, kind: args.kind)
            print("[swift-render] created \(url.path)")
            print("[swift-render] it is auto-registered — next: swift run swift-render check \(args.sceneName)")
        } catch {
            fputs("[swift-render] \(error.localizedDescription)\n", stderr); exit(1)
        }
        return
    case "render", "frame", "props", "contact", "audio", "check", "preview", "captions":
        warnIfShadersStale()
    default:
        fputs("Unknown subcommand: \(args.subcommand)\n", stderr)
        printUsage()
        exit(1)
    }

    guard let runner = sceneRunners[args.sceneName] else {
        fputs("Unknown scene: \(args.sceneName)\n", stderr)
        fputs("Try: swift-render list\n", stderr)
        exit(1)
    }

    if args.subcommand == "props" {
        if let template = runner.propsTemplate {
            print(template())
        } else {
            fputs("\(args.sceneName) takes no props\n", stderr)
            exit(1)
        }
        return
    }

    let duration = args.duration ?? runner.defaultDuration
    let size = args.size ?? args.aspect.size
    let audioURL = args.audio.map { URL(fileURLWithPath: $0) }
    let propsURL = args.props.map { URL(fileURLWithPath: $0) }

    // Precedence: explicit --audio > scene-declared Score > silence.
    let audioSource: AudioSource
    if let audioURL {
        audioSource = .file(audioURL)
    } else if let score = runner.soundtrack(duration) {
        audioSource = .score(score)
    } else {
        audioSource = .none
    }

    if args.subcommand == "captions" {
        guard let score = runner.soundtrack(duration) else {
            fputs("\(args.sceneName) declares no soundtrack\n", stderr)
            exit(1)
        }
        let track = CaptionTrack(score)
        guard !track.cues.isEmpty else {
            fputs("\(args.sceneName) has no speak(...) lines\n", stderr)
            exit(1)
        }
        let outPath = args.out == "out/render.mp4" ? "out/\(args.sceneName).srt" : args.out
        let body = outPath.lowercased().hasSuffix(".vtt") ? track.vtt() : track.srt()
        let url = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        print("[swift-render] \(track.cues.count) captions → \(outPath)")
        return
    }

    if args.subcommand == "preview" {
        try runPreview(runner: runner, name: args.sceneName, duration: duration, size: size,
                       fps: args.fps, audio: audioSource, propsURL: propsURL,
                       postFX: args.postFX && !runner.ownsPostFX, snapshot: args.snapshot)
        return
    }

    if args.subcommand == "audio" {
        guard let score = runner.soundtrack(duration) else {
            fputs("\(args.sceneName) declares no soundtrack\n", stderr)
            exit(1)
        }
        let outPath = args.out == "out/render.mp4" ? "out/score.wav" : args.out
        try ScoreSynth.writeWAV(score, to: URL(fileURLWithPath: outPath))
        print(String(format: "[swift-render] score %.2fs (%d events) → %@",
                     score.duration, score.events.count, outPath))
        return
    }

    let isPreview = args.preview && args.subcommand == "render"
    let config = Recorder.Config(
        fps: isPreview ? min(args.fps, 30) : args.fps,
        size: size,
        scale: isPreview ? args.scale * 0.5 : args.scale,
        postFX: args.postFX
    )
    let recorder = Recorder(config: config)

    if args.subcommand == "contact" || args.subcommand == "check" {
        let isCheck = args.subcommand == "check"
        let defaultOut = isCheck ? "out/check-\(args.sceneName).png" : "out/contact.png"
        let outPath = args.out == "out/render.mp4" ? defaultOut : args.out
        // full-size layout, downscaled by ImageRenderer — scenes keep their 1080p coordinates
        let thumbConfig = Recorder.Config(fps: args.fps, size: size,
                                          scale: 384.0 / size.width, postFX: args.postFX)
        let thumbRecorder = Recorder(config: thumbConfig)
        let cols = isCheck && args.cols == 5 && args.rows == 3 ? 4 : args.cols
        let rows = isCheck && args.cols == 5 && args.rows == 3 ? 4 : args.rows
        let n = cols * rows
        // sample each cell's midpoint: endpoints land on beat-grid cuts and fades,
        // which are exactly the frames that don't represent the shot
        let step = duration / Double(max(1, n))
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-contact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        var cells: [(Double, URL)] = []
        let t0 = Date()
        for i in 0..<n {
            let t = (Double(i) + 0.5) * step
            let cell = tmpDir.appendingPathComponent(String(format: "c%03d.png", i))
            try runner.frame(thumbRecorder, cell, t, duration, audioSource, propsURL)
            cells.append((t, cell))
        }
        let perFrame = Date().timeIntervalSince(t0) / Double(n)
        try composeContactSheet(cells: cells, columns: cols, to: URL(fileURLWithPath: outPath))
        print("[swift-render] contact sheet \(cols)×\(rows) → \(outPath)")
        guard isCheck else { return }

        var report: [String] = []
        report.append(String(format: "scene %@ · %.2fs · %d×%d @ %dfps · %d frames · %.0f ms/thumb",
                             args.sceneName, duration, Int(size.width), Int(size.height), args.fps,
                             Int(duration * Double(args.fps)), perFrame * 1000))
        let flat = cells.compactMap { t, url -> Double? in
            guard let sd = luminanceSpread(url) else { return nil }
            return sd < 0.015 ? t : nil
        }
        if flat.isEmpty { report.append("frames: no blank samples") }
        else {
            let edge = flat.allSatisfy { $0 < step || $0 > duration - step }
            report.append("frames: flat/blank at " + flat.map { String(format: "%.2fs", $0) }.joined(separator: ", ")
                          + (edge ? " (start/end fades — fine)" : "  ⚠︎ check these"))
        }
        switch audioSource {
        case .score(let score):
            let (l, r) = ScoreSynth.render(score)
            report += audioReport(left: l, right: r, rate: scoreSampleRate, events: score.events)
            report += mediaReport(score)
        case .file(let url):
            let a = try loadAudioFile(url)
            report += audioReport(left: a.left, right: a.right, rate: a.rate, events: nil)
        case .none:
            report.append("audio: none — add `soundtrack(duration:)` or pass --audio")
        }
        let text = report.joined(separator: "\n")
        print(text)
        let txt = URL(fileURLWithPath: outPath).deletingPathExtension().appendingPathExtension("txt")
        try (text + "\n").write(to: txt, atomically: true, encoding: .utf8)
        print("[swift-render] report → \(txt.path)")
        return
    }

    if args.subcommand == "frame" {
        let base = args.out == "out/render.mp4" ? "out/frame.png" : args.out
        for t in args.at {
            let outPath = args.at.count == 1 ? base
                : (base as NSString).deletingPathExtension + String(format: "_%.2f.png", t)
            try runner.frame(recorder, URL(fileURLWithPath: outPath), t, duration, audioSource, propsURL)
            print("[swift-render] frame t=\(t)s → \(outPath)")
        }
        return
    }

    let outURL = URL(fileURLWithPath: args.out)
    if args.rangeStart != nil && args.audio != nil {
        fputs("[swift-render] note: --range renders are picture-only; render the full scene to mux audio\n", stderr)
    }
    let startTime = args.rangeStart ?? 0
    let endTime = args.rangeEnd ?? duration
    let totalFrames = Int(((endTime - startTime) * Double(config.fps)).rounded())
    print("[swift-render] scene=\(args.sceneName) duration=\(duration)s range=\(startTime)-\(endTime)s fps=\(config.fps) size=\(Int(size.width * config.scale))×\(Int(size.height * config.scale))\(isPreview ? " (preview)" : "") frames=\(totalFrames) → \(args.out)")
    switch audioSource {
    case .file(let u): print("[swift-render] audio: \(u.path)")
    case .score(let sc): print(String(format: "[swift-render] audio: synthesized score (%d events)", sc.events.count))
    case .none: break
    }

    let start = Date()
    if args.jobs > 1 && args.rangeStart == nil {
        try await renderParallel(jobs: args.jobs, scene: args.sceneName, duration: duration, fps: config.fps,
                                 audio: audioSource, out: outURL)
    } else {
        try await runner.render(recorder, outURL, startTime, endTime, duration, audioSource, args.rangeStart == nil, propsURL)
    }
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "[swift-render] done in %.1fs → %@", elapsed, args.out))
    if args.open { NSWorkspace.shared.open(outURL) }
}

try await run()
