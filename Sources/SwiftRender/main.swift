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

// MARK: - Scene registry

let sceneRunners: [String: SceneRunner] = [
    // Generic scenes (Cookbook + library — public API examples)
    "TextReveal":       SceneRunner(TextReveal.self),
    "CardStack":        SceneRunner(CardStack.self),
    "ParticleField":    SceneRunner(ParticleField.self),
    "ShaderShowcase":   SceneRunner(ShaderShowcase.self),

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
    let render: (Recorder, URL, Double, URL?) async throws -> Void

    init<S: RenderScene>(_ type: S.Type) {
        self.defaultDuration = S.defaultDuration
        self.render = { recorder, out, dur, audio in
            try await recorder.render(to: out, duration: dur, audioURL: audio) { t in
                S.body(at: t, duration: dur)
            }
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
    case "render":
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

    let outURL = URL(fileURLWithPath: args.out)
    let duration = args.duration ?? runner.defaultDuration
    let size = args.size ?? args.aspect.size
    let audioURL = args.audio.map { URL(fileURLWithPath: $0) }

    let config = Recorder.Config(
        fps: args.fps,
        size: size,
        scale: args.scale
    )
    let recorder = Recorder(config: config)

    let totalFrames = Int((duration * Double(args.fps)).rounded())
    print("[swift-render] scene=\(args.sceneName) duration=\(duration)s fps=\(args.fps) size=\(Int(size.width))×\(Int(size.height)) frames=\(totalFrames) → \(args.out)")
    if let audioURL = audioURL { print("[swift-render] audio: \(audioURL.path)") }

    let start = Date()
    try await runner.render(recorder, outURL, duration, audioURL)
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "[swift-render] done in %.1fs → %@", elapsed, args.out))
}

try await run()
