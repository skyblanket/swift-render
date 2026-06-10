import AVFoundation
import CoreText
import Foundation
import SwiftUI

// MARK: - Font registration

@MainActor
func registerBundledFonts() {
    let bundle = Bundle.module
    let names = ["Inter", "InterVariable"]
    for name in names {
        for ext in ["ttc", "ttf"] {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                var error: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    if let e = error?.takeRetainedValue() {
                        let desc = CFErrorCopyDescription(e) as String
                        if !desc.contains("already") {
                            fputs("font register fail \(name).\(ext): \(desc)\n", stderr)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shader freshness

/// default.metallib is pre-compiled and checked in; editing a .metal file does
/// nothing until it is rebuilt. Catch that silently-stale state loudly.
func checkShaderFreshness() {
    let bundle = Bundle.module
    let fm = FileManager.default
    guard let lib = bundle.url(forResource: "default", withExtension: "metallib"),
          let libDate = (try? fm.attributesOfItem(atPath: lib.path))?[.modificationDate] as? Date
    else { return }
    let stale = (bundle.urls(forResourcesWithExtension: "metal", subdirectory: nil) ?? [])
        .filter { url in
            ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                .map { $0 > libDate } ?? false
        }
        .map(\.lastPathComponent)
    if !stale.isEmpty {
        fputs("""
        !!! ────────────────────────────────────────────────────────────────
        !!! STALE SHADERS: \(stale.joined(separator: ", "))
        !!!   are newer than default.metallib — your .metal edits are NOT live.
        !!!   Fix:  tools/build_shaders.sh && swift build
        !!! ────────────────────────────────────────────────────────────────

        """, stderr)
    }
}

// MARK: - Scene registry

let sceneRunners: [String: SceneRunner] = [
    // Generic scenes (Cookbook + library — public API examples)
    "TextReveal":       SceneRunner(TextReveal.self),
    "Kinetic":          SceneRunner(Kinetic.self),
    "JustRenderIt":     SceneRunner(JustRenderIt.self),
    "AudioBars":        SceneRunner(AudioBars.self),
    "CardStack":        SceneRunner(CardStack.self),
    "ParticleField":    SceneRunner(ParticleField.self),
    "ShaderShowcase":   SceneRunner(ShaderShowcase.self),
    "ShaderGallery":    SceneRunner(ShaderGallery.self),

    // OpenEar — real-world consumer scenes living inside the repo
    "LogoReveal":       SceneRunner(LogoReveal.self),
    "NotchRecording":   SceneRunner(NotchRecording.self),
    "WaveformDance":    SceneRunner(WaveformDance.self),
    "VinylSpin":        SceneRunner(VinylSpin.self),
    "DahliaProcessing": SceneRunner(DahliaProcessing.self),
    "WelcomeSplash":    SceneRunner(WelcomeSplash.self),
    "LaunchReel":       SceneRunner(LaunchReel.self),
    "IGHook":           SceneRunner(IGHook.self),
    "IGOutro":          SceneRunner(IGOutro.self),
]

@MainActor
struct SceneRunner {
    let defaultDuration: Double
    /// Pretty-printed default-props JSON; nil for prop-less scenes.
    let propsTemplate: (() -> String)?
    /// (recorder, outURL, endTime, startTime, audioURL, propsURL)
    let render: (Recorder, URL, Double, Double, URL?, URL?) async throws -> Void
    /// (recorder, outURL, t, duration, audioURL, propsURL)
    let frame: (Recorder, URL, Double, Double, URL?, URL?) throws -> Void

    init<S: RenderScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = nil
        render = { recorder, out, dur, start, audio, _ in
            try await recorder.render(to: out, duration: dur, startTime: start, audioURL: audio) { t in
                S.body(at: t, duration: dur)
            }
        }
        frame = { recorder, out, t, dur, _, _ in
            try recorder.renderPNG(at: t, to: out) { tt in
                S.body(at: tt, duration: dur)
            }
        }
    }

    init<S: AudioReactiveScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = nil
        render = { recorder, out, dur, start, audio, _ in
            let track = try audio.map { try AudioAnalyzer.analyze(url: $0, fps: recorder.config.fps) } ?? .silent
            try await recorder.render(to: out, duration: dur, startTime: start, audioURL: audio) { t in
                S.body(at: t, duration: dur, audio: track)
            }
        }
        frame = { recorder, out, t, dur, audio, _ in
            let track = try audio.map { try AudioAnalyzer.analyze(url: $0, fps: recorder.config.fps) } ?? .silent
            try recorder.renderPNG(at: t, to: out) { tt in
                S.body(at: tt, duration: dur, audio: track)
            }
        }
    }

    init<S: PropsScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = { Self.templateJSON(S.defaultProps) }
        render = { recorder, out, dur, start, audio, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            try await recorder.render(to: out, duration: dur, startTime: start, audioURL: audio) { t in
                S.body(at: t, duration: dur, props: props)
            }
        }
        frame = { recorder, out, t, dur, _, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            try recorder.renderPNG(at: t, to: out) { tt in
                S.body(at: tt, duration: dur, props: props)
            }
        }
    }

    init<S: PropsAudioScene>(_ type: S.Type) {
        defaultDuration = S.defaultDuration
        propsTemplate = { Self.templateJSON(S.defaultProps) }
        render = { recorder, out, dur, start, audio, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let track = try audio.map { try AudioAnalyzer.analyze(url: $0, fps: recorder.config.fps) } ?? .silent
            try await recorder.render(to: out, duration: dur, startTime: start, audioURL: audio) { t in
                S.body(at: t, duration: dur, props: props, audio: track)
            }
        }
        frame = { recorder, out, t, dur, audio, propsURL in
            let props = try Self.loadProps(S.Props.self, defaults: S.defaultProps, from: propsURL)
            let track = try audio.map { try AudioAnalyzer.analyze(url: $0, fps: recorder.config.fps) } ?? .silent
            try recorder.renderPNG(at: t, to: out) { tt in
                S.body(at: tt, duration: dur, props: props, audio: track)
            }
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
    var at: Double = 0          // `frame` subcommand: timestamp
    var rangeStart: Double? = nil
    var rangeEnd: Double? = nil
    var props: String? = nil
}

func parseArgs(_ argv: [String]) -> CLIArgs {
    if argv.count < 2 {
        printUsage()
        exit(1)
    }

    let sub = argv[1]
    var args = CLIArgs(subcommand: sub)

    if sub == "list" || sub == "--help" || sub == "-h" {
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
        case "--at":       args.at = Double(v) ?? 0; i += 2
        case "--props":    args.props = v; i += 2
        case "--range":
            let parts = v.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { args.rangeStart = parts[0]; args.rangeEnd = parts[1] }
            i += 2
        default:           i += 1
        }
    }
    return args
}

func printUsage() {
    fputs("""
    swift-render — programmatic motion graphics in Swift

    USAGE:
      swift-render render <Scene> [opts]    Render a scene to MP4
      swift-render frame <Scene> --at <t>   Render one frame to PNG (fast preview)
      swift-render props <Scene>            Print a scene's default props as JSON
      swift-render list                     List available scenes
      swift-render --help                   Show this help

    SCENE OPTIONS:
      --duration <seconds>     Override scene's default duration
      --fps <n>                Frame rate (default 60)
      --aspect 16:9|9:16|1:1   Output aspect (default 16:9)
      --width <px>             Custom width (overrides --aspect)
      --height <px>            Custom height
      --scale <n>              Display scale (default 1.0)
      --out <path>             Output mp4 path (default out/render.mp4)
      --audio <path>           Optional audio file to mux into the output
      --range <a:b>            Render only seconds a..b (audio mux skipped)
      --at <t>                 Frame timestamp for the `frame` subcommand
      --props <file.json>      JSON props for parameterized scenes

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
    checkShaderFreshness()
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
    case "render", "frame", "props":
        break
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

    let config = Recorder.Config(
        fps: args.fps,
        size: size,
        scale: args.scale
    )
    let recorder = Recorder(config: config)

    if args.subcommand == "frame" {
        let outPath = args.out == "out/render.mp4" ? "out/frame.png" : args.out
        let outURL = URL(fileURLWithPath: outPath)
        try runner.frame(recorder, outURL, args.at, duration, audioURL, propsURL)
        print("[swift-render] frame t=\(args.at)s → \(outPath)")
        return
    }

    let outURL = URL(fileURLWithPath: args.out)
    let startTime = args.rangeStart ?? 0
    let endTime = args.rangeEnd ?? duration
    let totalFrames = Int(((endTime - startTime) * Double(args.fps)).rounded())
    print("[swift-render] scene=\(args.sceneName) duration=\(duration)s range=\(startTime)-\(endTime)s fps=\(args.fps) size=\(Int(size.width))×\(Int(size.height)) frames=\(totalFrames) → \(args.out)")
    if let audioURL = audioURL { print("[swift-render] audio: \(audioURL.path)") }

    let start = Date()
    try await runner.render(recorder, outURL, endTime, startTime, args.rangeStart == nil ? audioURL : nil, propsURL)
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "[swift-render] done in %.1fs → %@", elapsed, args.out))
}

try await run()
