import AppKit
import Foundation
import SwiftRender
import SwiftRenderKit

// MARK: - swift-render launch / init
//
// `launch [path]`: scan a Swift codebase, write its props to
//   <path>/.swift-render/launch/<Name>.json, and render the AppleLaunch film in-process.
//   An existing props file is reused (it is the thing you, Studio or the agent edit);
//   `--rescan` replaces it.
// `init [path]`: scaffold <path>/Launch/ — a package with your own editable launch
//   scene (LaunchKit + the scanned props as defaults) and a `launch` CLI.

struct LaunchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Template scenes every project gets (merged under the project's own registry).
@MainActor
func builtinSceneRunners() -> [String: SceneRunner] {
    ["AppleLaunch": SceneRunner(AppleLaunch.self)]
}

private struct LaunchArgs {
    var path = "."
    var out: String?
    var aspect: AspectPreset = .landscape16x9
    var propsOut: String?
    var voiceover = false
    var preview = false
    var open = false
    var eject = false
    var rescan = false
    var noRender = false
    var manifest = true
    var fps = 60
    var local: String?
    var force = false
}

private func parseLaunchArgs(_ argv: [String], command: String) throws -> LaunchArgs {
    var a = LaunchArgs()
    var i = 0, positional = false
    while i < argv.count {
        let k = argv[i], v = i + 1 < argv.count ? argv[i + 1] : ""
        switch k {
        case "--out": a.out = v; i += 2
        case "--aspect":
            guard let p = AspectPreset(rawValue: v) else { throw LaunchError("--aspect must be 16:9, 9:16 or 1:1") }
            a.aspect = p; i += 2
        case "--props-out": a.propsOut = v; i += 2
        case "--fps": a.fps = Int(v) ?? 60; i += 2
        case "--local": a.local = v; i += 2
        case "--voiceover": a.voiceover = true; i += 1
        case "--preview": a.preview = true; i += 1
        case "--open": a.open = true; i += 1
        case "--eject": a.eject = true; i += 1
        case "--rescan": a.rescan = true; i += 1
        case "--no-render": a.noRender = true; i += 1
        case "--no-manifest": a.manifest = false; i += 1
        case "--force": a.force = true; i += 1
        case "-h", "--help":
            throw LaunchError(command == "init" ? initUsage : launchUsage)
        default:
            guard !k.hasPrefix("--"), !positional else { throw LaunchError("unknown option \(k)\n\n" + (command == "init" ? initUsage : launchUsage)) }
            a.path = k; positional = true; i += 1
        }
    }
    return a
}

private let launchUsage = """
usage: swift-render launch [path=.] [--out film.mp4] [--aspect 16:9|9:16] [--props-out props.json]
                           [--voiceover] [--preview] [--open] [--eject] [--rescan] [--no-render] [--no-manifest]

  Scans the Swift codebase at <path> (Package.swift, .xcodeproj, Assets.xcassets, Info.plist,
  README, CHANGELOG, git) and renders an Apple-style launch film with the AppleLaunch scene.
  Props are kept in <path>/.swift-render/launch/<Name>.json — edit them and run again.
    --rescan       re-scan and overwrite the props file
    --no-render    scan and write props only
    --eject        also write an editable copy of the film as Swift into the project's scenes dir
    --no-manifest  don't run `swift package dump-package` (for untrusted code)
"""

private let initUsage = """
usage: swift-render init [path=.] [--local <swift-render checkout>] [--force]

  Scaffolds <path>/Launch/: a Swift package with your own launch scene
  (Sources/LaunchScenes/<App>Launch.swift, LaunchKit + the scanned props) and a `launch` CLI.
    cd Launch && swift run launch render <App>Launch --open
"""

// MARK: - launch

@MainActor
func runLaunch(_ argv: [String]) async throws {
    let a = try parseLaunchArgs(argv, command: "launch")
    let root = URL(fileURLWithPath: a.path, isDirectory: true).standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.path) else { throw LaunchError("no such directory: \(root.path)") }

    let started = Date()
    let (scanned, report) = scanForLaunch(root, manifest: a.manifest)
    let launchDir = root.appendingPathComponent(".swift-render/launch", isDirectory: true)
    try FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
    let propsURL = launchDir.appendingPathComponent("\(fileSafe(scanned.name)).json")
    let reportURL = launchDir.appendingPathComponent("\(fileSafe(scanned.name)).scan.json")

    var props = scanned
    var reused = false
    if !a.rescan, let data = try? Data(contentsOf: propsURL), let existing = try? JSONDecoder().decode(LaunchProps.self, from: data) {
        props = existing
        reused = true
    }
    if a.voiceover { props.voiceover = true }
    let (valid, warnings) = props.validated()

    if !reused || a.voiceover { try writeJSON(props, to: propsURL) }
    try writeJSON(report, to: reportURL)
    if let po = a.propsOut { try writeJSON(props, to: URL(fileURLWithPath: po)) }

    printSummary(valid, report: report, warnings: warnings, root: root, scanSeconds: Date().timeIntervalSince(started))
    print("  props       \(relative(propsURL, to: root))\(reused ? "  (existing — edit it, or --rescan)" : "")")
    print("  scan report \(relative(reportURL, to: root))")
    if let po = a.propsOut { print("  props copy  \(po)") }

    if a.eject {
        let url = try ejectScene(props: valid, root: root)
        print("  ejected     \(url.path)")
    }
    guard !a.noRender else { return }

    // Relative icon/screenshot paths in the props are relative to the scanned root.
    if !AssetPaths.extraSearchPaths.contains(root) { AssetPaths.extraSearchPaths.append(root) }
    let runner = SceneRunner(AppleLaunch.self)
    let duration = runner.durationFor(propsURL)
    let size = a.aspect.size
    let fps = a.preview ? min(a.fps, 30) : a.fps
    let config = Recorder.Config(fps: fps, size: size, scale: a.preview ? 0.5 : 1, postFX: true)
    let suffix = a.aspect == .vertical9x16 ? "-9x16" : a.aspect == .square1x1 ? "-1x1" : ""
    let outURL = a.out.map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("out/\(fileSafe(valid.name).lowercased())-launch\(suffix).mp4")
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let audio: AudioSource = runner.soundtrack(duration, propsURL).map { .score($0) } ?? .none
    let total = Int((duration * Double(fps)).rounded())
    print(String(format: "[swift-render] rendering AppleLaunch · %.1fs · %d×%d @ %dfps%@ · %d frames",
                 duration, Int(size.width * config.scale), Int(size.height * config.scale), fps,
                 a.preview ? " (preview)" : "", total))
    let t0 = Date()
    var lastDecile = -1
    let span = RenderSpan(duration: duration, start: 0, end: duration) { done, all in
        let decile = all > 0 ? done * 10 / all : 0
        if decile != lastDecile { lastDecile = decile; fputs("\r[swift-render] \(decile * 10)%", stderr) }
    }
    try await runner.render(Recorder(config: config), outURL, span, audio, propsURL)
    fputs("\n", stderr)
    print(String(format: "[swift-render] film → %@  (%.1fs)", outURL.path, Date().timeIntervalSince(t0)))
    print("[swift-render] iterate: edit \(relative(propsURL, to: root)), then `swift-render check AppleLaunch --props \(propsURL.path)`")
    if a.open { NSWorkspace.shared.open(outURL) }
}

/// Scan, then fill the accent from the icon when the codebase declares none.
func scanForLaunch(_ root: URL, manifest: Bool) -> (LaunchProps, LaunchScanReport) {
    var (props, report) = LaunchScanner(root: root, options: .init(executeManifest: manifest)).scan()
    if report.missing.contains(where: { $0.hasPrefix("accent") }), let icon = props.icon,
       let hex = dominantColor(root.appendingPathComponent(icon.path)) {
        props.accent = hex
        report.missing.removeAll { $0.hasPrefix("accent") }
        report.evidence.append(.init(field: "accent", value: hex, source: "\(icon.path) (dominant hue)"))
    }
    return (props, report)
}

/// The most saturated hue family in an image, as "#RRGGBB" (nil for greyscale art).
func dominantColor(_ url: URL) -> String? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    let n = 48
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()
    var bins = [Double](repeating: 0, count: 12)
    var sums = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: 12)
    for y in 0..<n { for x in 0..<n {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
        let s = Double(c.saturationComponent), b = Double(c.brightnessComponent)
        guard s > 0.3, b > 0.3 else { continue }
        let bin = min(11, Int(Double(c.hueComponent) * 12))
        let w = s * b
        bins[bin] += w
        sums[bin].0 += Double(c.redComponent) * w; sums[bin].1 += Double(c.greenComponent) * w
        sums[bin].2 += Double(c.blueComponent) * w; sums[bin].3 += w
    } }
    guard let best = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[best] > Double(n * n) * 0.02 else { return nil }
    let s = sums[best]
    return LaunchColor.hex(s.0 / s.3, s.1 / s.3, s.2 / s.3)
}

private func printSummary(_ p: LaunchProps, report: LaunchScanReport, warnings: [String], root: URL, scanSeconds: Double) {
    func row(_ label: String, _ value: String, _ field: String? = nil) {
        let src = field.flatMap { report.source(of: $0) }.map { "   ← \($0)" } ?? ""
        print("  " + label.padding(toLength: 12, withPad: " ", startingAt: 0) + value + src)
    }
    print(String(format: "[swift-render] launch: scanned %@ (%.1fs)", root.path, scanSeconds))
    row("name", p.name, "name")
    row("kind", p.kind.rawValue, "kind")
    row("tagline", p.tagline, "tagline")
    if let s = p.subtitle { row("subtitle", s, "subtitle") }
    row("features", p.features.isEmpty ? "—" : p.features.map(\.title).joined(separator: " · "), "features")
    row("icon", p.icon?.path ?? "none — using a generated mark", "icon")
    row("accent", p.accent, "accent")
    if let v = p.version { row("version", v + (p.releaseDate.map { " (\($0))" } ?? ""), "version") }
    if !p.platforms.isEmpty { row("platforms", p.platforms.map { PlatformBadges.label($0) }.joined(separator: " · ")) }
    if let c = p.code { row("code", "\(c.title ?? "snippet") · \(c.source.components(separatedBy: "\n").count) lines", "code") }
    if let term = p.terminal { row("terminal", term.filter { $0.hasPrefix("$ ") }.joined(separator: "  "), "terminal") }
    if !p.highlights.isEmpty {
        row("numbers", p.highlights.map { "\(StatCounter.format($0.value, $0)) \($0.label)" }.joined(separator: " · "))
    }
    if !p.changelog.isEmpty { row("changelog", "\(p.changelog.count) items", "changelog") }
    if !p.screenshots.isEmpty { row("screens", p.screenshots.map(\.path).joined(separator: ", ")) }
    let plan = LaunchPlan(p)
    let bars = plan.shots.reduce(0) { $0 + $1.bars }
    row("shots", plan.shots.map { "\($0.id) \(Int($0.bars))" }.joined(separator: " · ")
        + String(format: "  = %g bars, %.1fs @ %d BPM", bars, plan.duration, Int(plan.bpm)))
    for c in report.conflicts { print("  conflict    \(c)") }
    for m in report.missing { print("  missing     \(m)") }
    for w in report.warnings + warnings { print("  note        \(w)") }
}

// MARK: - init

@MainActor
func runInit(_ argv: [String]) throws {
    let a = try parseLaunchArgs(argv, command: "init")
    let root = URL(fileURLWithPath: a.path, isDirectory: true).standardizedFileURL
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { throw LaunchError("no such directory: \(root.path)") }
    let dir = root.appendingPathComponent("Launch", isDirectory: true)
    if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) && !a.force {
        throw LaunchError("\(dir.path) already exists (use --force to overwrite the scaffold files)")
    }

    var (props, report) = scanForLaunch(root, manifest: a.manifest)
    let typeName = swiftTypeName(props.name) + "Launch"

    // Copy art into Launch/assets so the package renders from anywhere.
    let assets = dir.appendingPathComponent("assets", isDirectory: true)
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    if let icon = props.icon {
        let ext = (icon.path as NSString).pathExtension.isEmpty ? "png" : (icon.path as NSString).pathExtension
        let dest = assets.appendingPathComponent("AppIcon.\(ext)")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: root.appendingPathComponent(icon.path), to: dest)
        props.icon?.path = "assets/AppIcon.\(ext)"
    }
    for (i, shot) in props.screenshots.enumerated() {
        let dest = assets.appendingPathComponent("screenshot-\(i + 1).\((shot.path as NSString).pathExtension)")
        try? fm.removeItem(at: dest)
        if (try? fm.copyItem(at: root.appendingPathComponent(shot.path), to: dest)) != nil {
            props.screenshots[i].path = "assets/" + dest.lastPathComponent
        }
    }

    let dependency: String
    let packageRef: String
    if let local = a.local {
        let path = URL(fileURLWithPath: local, isDirectory: true).standardizedFileURL
        guard fm.fileExists(atPath: path.appendingPathComponent("Package.swift").path) else {
            throw LaunchError("--local \(path.path) has no Package.swift")
        }
        // A path dependency's identity is its folder name.
        packageRef = path.lastPathComponent.lowercased()
        dependency = ".package(path: \(swiftString(path.path)))"
    } else {
        packageRef = "swift-render"
        dependency = ".package(url: \"https://github.com/skyblanket/swift-render\", from: \"0.10.0\")"
    }

    let files: [(String, String)] = [
        ("Package.swift", packageManifest(dependency: dependency, packageRef: packageRef)),
        ("Sources/launch/main.swift", mainSwift),
        ("Sources/LaunchScenes/\(typeName).swift", sceneSource(typeName: typeName, props: props.validated().props, external: true)),
        ("swift-render.json", "{\n  \"product\": \"launch\",\n  \"scenesDir\": \"Sources/LaunchScenes\"\n}\n"),
        (".mcp.json", mcpJSON),
        (".gitignore", ".build/\n.swiftpm/\nout/\n.swift-render/cache/\n"),
        ("README.md", launchReadme(typeName: typeName, name: props.name)),
    ]
    for (rel, body) in files {
        let url = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    let launchDir = dir.appendingPathComponent(".swift-render/launch", isDirectory: true)
    try fm.createDirectory(at: launchDir, withIntermediateDirectories: true)
    try writeJSON(props, to: launchDir.appendingPathComponent("\(typeName).json"))
    try writeJSON(report, to: launchDir.appendingPathComponent("\(typeName).scan.json"))

    print("[swift-render] init: \(dir.path)")
    for (rel, _) in files { print("  \(rel)") }
    if props.icon != nil { print("  assets/AppIcon.png") }
    print("  .swift-render/launch/\(typeName).json   (the scanned props, for `--props` experiments)")
    for m in report.missing { print("  missing     \(m)") }
    print("""

    next:
      cd \(relative(dir, to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
      swift run launch check \(typeName)                 # contact sheet + audio report
      swift run launch render \(typeName) --preview --open
      swift run launch render \(typeName) --aspect 9:16 --out out/\(typeName)-vertical.mp4
    """)
}

private func packageManifest(dependency: String, packageRef: String) -> String {
    """
    // swift-tools-version: 5.10
    import PackageDescription

    // Your launch film, as code. `swift run launch list` shows the scenes;
    // edit Sources/LaunchScenes and re-render. Scenes are registered automatically.
    let package = Package(
        name: "Launch",
        platforms: [.macOS(.v14)],
        products: [
            .executable(name: "launch", targets: ["LaunchCLI"]),
        ],
        dependencies: [
            \(dependency),
        ],
        targets: [
            .target(
                name: "LaunchScenes",
                dependencies: [
                    .product(name: "SwiftRender", package: "\(packageRef)"),
                    .product(name: "SwiftRenderKit", package: "\(packageRef)"),
                ]
            ),
            // The module isn't called `launch`: that name is taken by a Darwin SDK module
            // Foundation depends on, and shadowing it breaks every other build in the package.
            .executableTarget(
                name: "LaunchCLI",
                dependencies: [
                    "LaunchScenes",
                    .product(name: "SwiftRender", package: "\(packageRef)"),
                    .product(name: "SwiftRenderTool", package: "\(packageRef)"),
                ],
                path: "Sources/launch",
                plugins: [.plugin(name: "SceneRegistryPlugin", package: "\(packageRef)")]
            ),
        ]
    )

    """
}

private let mainSwift = """
import Foundation
import SwiftRender
import SwiftRenderTool

// Resolve `assets/…` paths against this package, wherever `swift run` is invoked from.
let packageDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
AssetPaths.extraSearchPaths.append(packageDir)

// `generatedSceneRunners` is written at build time by SceneRegistryPlugin: every
// `public struct X: …Scene` in Sources/LaunchScenes, registered as "X".
await SwiftRenderCommand.main(scenes: generatedSceneRunners)

"""

/// Same launcher as swift-render's own `.mcp.json`: build output goes to stderr so it can't
/// corrupt the stdio protocol, then the server runs from the project root (found from the cwd).
private let mcpJSON = #"""
{
  "mcpServers": {
    "swift-render": {
      "type": "stdio",
      "command": "sh",
      "args": [
        "-c",
        "swift build -q --product swift-render-mcp 1>&2 && exec \"$(swift build --show-bin-path)/swift-render-mcp\""
      ]
    }
  }
}

"""#

private func launchReadme(typeName: String, name: String) -> String {
    """
    # \(name) — launch film

    Made with [swift-render](https://github.com/skyblanket/swift-render). The film is
    `Sources/LaunchScenes/\(typeName).swift`: a `PropsScene` built from LaunchKit, with the
    props scanned from this codebase as its defaults. Edit the props (copy, features, accent,
    shots) or the Swift, then re-render.

    ```bash
    swift run launch list
    swift run launch check \(typeName)                       # contact sheet + audio report
    swift run launch render \(typeName) --preview --open     # half-res, 30 fps
    swift run launch render \(typeName) --out out/launch.mp4
    swift run launch render \(typeName) --aspect 9:16 --out out/launch-vertical.mp4
    swift run launch render \(typeName) --props .swift-render/launch/\(typeName).json   # JSON instead of the Swift defaults
    ```

    - `assets/` holds the icon and screenshots the film uses.
    - Review comments live in `.swift-render/reviews/`; `.mcp.json` registers the swift-render
      MCP server so Claude Code can pick up comments, edit the scene and re-render.
      Run `swift build` once first so the server starts fast.
    - Shots: drop one with `shots: [.init(id: "stats", hidden: true)]`, lengthen one with
      `.init(id: "triad", bars: 3)`. Tempo is 90, 100 or 120 BPM so cuts land on frames.

    """
}

// MARK: - eject

/// Writes an editable `<Name>Launch.swift` into the project's scenes directory.
func ejectScene(props: LaunchProps, root: URL) throws -> URL {
    let project = Project.discover(from: root)
    let base = project?.root ?? root
    let dir: String
    if let d = project?.config.scenesDir { dir = d }
    else if FileManager.default.fileExists(atPath: base.appendingPathComponent("Sources/SwiftRender/Scenes").path) {
        dir = "Sources/SwiftRender/Scenes"
    } else {
        throw LaunchError("no scenes directory for \(base.path): run `swift-render init \(root.path)` to scaffold a Launch/ package")
    }
    let typeName = swiftTypeName(props.name) + "Launch"
    let url = base.appendingPathComponent(dir).appendingPathComponent("\(typeName).swift")
    guard !FileManager.default.fileExists(atPath: url.path) else { throw LaunchError("\(url.path) already exists") }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try sceneSource(typeName: typeName, props: props, external: !dir.hasPrefix("Sources/SwiftRender/"))
        .write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// An editable launch film: the AppleLaunch sequence spelled out shot by shot, with
/// the props as Swift defaults. Shots it doesn't override use the stock LaunchKit shot.
func sceneSource(typeName: String, props: LaunchProps, external: Bool) -> String {
    let staticName = lowerCamel(typeName)
    return """
    import SwiftUI
    \(external ? "import SwiftRender\nimport SwiftRenderKit\n" : "import SwiftRenderKit\n")
    /// \(typeName) — the \(props.name) launch film. Every shot is a pure function of
    /// its local time `l`; the plan (`LaunchPlan`) and the score (`LaunchScore`) are
    /// derived from the same props, so cuts and music stay locked together.
    ///
    ///   swift run \(external ? "launch" : "swift-render") check \(typeName)
    ///   swift run \(external ? "launch" : "swift-render") render \(typeName) --preview --open
    public struct \(typeName): PropsScene {
        public typealias Props = LaunchProps
        public static var defaultProps: LaunchProps { .\(staticName) }
        public static let defaultDuration: Double = LaunchPlan(.\(staticName)).duration
        public static var ownsPostFX: Bool { true }

        public static func duration(for props: LaunchProps) -> Double {
            LaunchPlan(props.validated().props).duration
        }

        public static func soundtrack(duration: Double, props: LaunchProps) -> Score? {
            let p = props.validated().props
            return LaunchScore.make(LaunchPlan(p), p, duration: duration)
        }

        @MainActor public static func body(at t: Double, duration: Double, props: LaunchProps) -> some View {
            let p = props.validated().props
            let plan = LaunchPlan(p)
            let theme = LaunchTheme(props: p)
            return ZStack {
                Stage(glow: 0.075 * Ease.easeInOut(Ease.clip(t, 0, 1.6)), at: t)
                Timeline(t) {
                    for (i, s) in plan.shots.enumerated() {
                        // The end card focus-pulls in; the shot before it runs 0.4 s over.
                        let intoEnd = i + 1 < plan.shots.count && plan.shots[i + 1].kind == .end
                        let len = plan.length(i) + (intoEnd ? 0.4 : 0)
                        if s.kind == .end {
                            Clip(len) { l in shot(s.kind, l, len, p, plan) }.transition(.focusPull(0.4))
                        } else {
                            Clip(len) { l in shot(s.kind, l, len, p, plan) }
                        }
                    }
                }
                theme.background.opacity(Ease.easeIn(Ease.clip(t, duration - 1.0, duration)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .launchTheme(theme)
            .launchPostFX(at: t, dark: theme.isDark)
        }

        @MainActor @ViewBuilder
        static func shot(_ kind: LaunchShot.Kind, _ l: Double, _ len: Double, _ p: LaunchProps, _ plan: LaunchPlan) -> some View {
            switch kind {
            case .title:
                // Your headline, your words: replace the tagline split with anything.
                KeynoteTitle(AppleLaunchShot.balance(p.tagline), sub: p.subtitle, at: l, start: 0.05, size: 132,
                             accentLine: 1, gradient: p.accentSecondary != nil)
                    .scaleEffect(Motion.push(l, over: len))
            default:
                // Stock LaunchKit shots: open, hero, triad, more, device, code, terminal,
                // stats, changelog, platforms, end. Replace any of them with your own case.
                AppleLaunchShot(kind, at: l, length: len, props: p, plan: plan)
            }
        }
    }

    public extension LaunchProps {
        /// Scanned from the codebase by `swift-render init`. Edit freely.
        static let \(staticName) = \(propsLiteral(props, indent: 4))
    }

    """
}

// MARK: - Props → Swift literal

/// `LaunchProps(...)` source for `p`, omitting defaults.
func propsLiteral(_ p: LaunchProps, indent: Int) -> String {
    let pad = String(repeating: " ", count: indent + 4)
    let pad2 = pad + "    "
    var args: [String] = ["name: \(swiftString(p.name))"]
    func add(_ label: String, _ value: String?) { if let value { args.append("\(label): \(value)") } }
    add("tagline", p.tagline.isEmpty ? nil : swiftString(p.tagline))
    add("subtitle", p.subtitle.map(swiftString))
    add("kind", ".\(p.kind.rawValue)")
    add("version", p.version.map(swiftString))
    add("releaseDate", p.releaseDate.map(swiftString))
    add("license", p.license.map(swiftString))
    add("url", p.url.map(swiftString))
    add("repo", p.repo.map(swiftString))
    add("accent", swiftString(p.accent))
    add("accentSecondary", p.accentSecondary.map(swiftString))
    add("appearance", p.appearance == .dark ? nil : ".\(p.appearance.rawValue)")
    add("typeface", p.typeface == .sfPro ? nil : ".\(p.typeface.rawValue)")
    add("icon", p.icon.map { ".init(path: \(swiftString($0.path))\($0.shape == .iOS ? "" : ", shape: .\($0.shape.rawValue)"))" })
    if !p.features.isEmpty {
        let items = p.features.map {
            "\(pad2).init(title: \(swiftString($0.title)), detail: \(swiftString($0.detail)), symbol: \(swiftString($0.symbol))"
                + ($0.screenshot.map { ", screenshot: \(swiftString($0))" } ?? "") + "),"
        }
        args.append("features: [\n" + items.joined(separator: "\n") + "\n\(pad)]")
    }
    add("code", p.code.map { snippetLiteral($0, pad: pad) })
    add("install", p.install.map { snippetLiteral($0, pad: pad) })
    add("terminal", p.terminal.map { "[" + $0.map(swiftString).joined(separator: ", ") + "]" })
    let s = p.stats
    let statArgs: [String] = [
        s.stars.map { "stars: \($0)" }, s.forks.map { "forks: \($0)" }, s.commits.map { "commits: \($0)" },
        s.contributors.map { "contributors: \($0)" }, s.swiftLines.map { "swiftLines: \($0)" },
        s.testCount.map { "testCount: \($0)" }, s.dependencies.map { "dependencies: \($0)" },
        s.releases.map { "releases: \($0)" }, s.targets.map { "targets: \($0)" },
        s.firstCommit.map { "firstCommit: \(swiftString($0))" },
    ].compactMap { $0 }
    if !statArgs.isEmpty { args.append("stats: .init(\(statArgs.joined(separator: ", ")))") }
    if !p.highlights.isEmpty {
        let items = p.highlights.map { h -> String in
            var a = ["value: \(h.value)", "format: .\(h.format.rawValue)", "label: \(swiftString(h.label))"]
            if let x = h.prefix { a.append("prefix: \(swiftString(x))") }
            if let x = h.suffix { a.append("suffix: \(swiftString(x))") }
            if let x = h.source { a.append("source: \(swiftString(x))") }
            return "\(pad2).init(\(a.joined(separator: ", "))),"
        }
        args.append("highlights: [\n" + items.joined(separator: "\n") + "\n\(pad)]")
    }
    if !p.platforms.isEmpty {
        args.append("platforms: [" + p.platforms.map { ".init(.\($0.name.rawValue)\($0.minimum.map { ", minimum: \(swiftString($0))" } ?? ""))" }
            .joined(separator: ", ") + "]")
    }
    add("swiftVersion", p.swiftVersion.map(swiftString))
    if !p.facts.isEmpty { args.append("facts: [" + p.facts.map(swiftString).joined(separator: ", ") + "]") }
    if !p.changelog.isEmpty {
        let items = p.changelog.map { "\(pad2).init(.\($0.kind.rawValue), \(swiftString($0.title))\($0.detail.map { ", detail: \(swiftString($0))" } ?? "")),"}
        args.append("changelog: [\n" + items.joined(separator: "\n") + "\n\(pad)]")
    }
    if !p.screenshots.isEmpty {
        let items = p.screenshots.map { "\(pad2).init(path: \(swiftString($0.path)), device: .\($0.device.rawValue)\($0.caption.map { ", caption: \(swiftString($0))" } ?? "")),"}
        args.append("screenshots: [\n" + items.joined(separator: "\n") + "\n\(pad)]")
    }
    var cta = [".\(p.cta.kind.rawValue)"]
    if let x = p.cta.title { cta.append("title: \(swiftString(x))") }
    if let x = p.cta.value { cta.append("value: \(swiftString(x))") }
    if let x = p.cta.from { cta.append("from: \(swiftString(x))") }
    if let x = p.cta.symbol { cta.append("symbol: \(swiftString(x))") }
    args.append("cta: .init(\(cta.joined(separator: ", ")))")
    if p.voiceover { args.append("voiceover: true") }
    if let lines = p.voiceoverLines, !lines.isEmpty {
        args.append("voiceoverLines: [" + lines.sorted { $0.key < $1.key }.map { "\(swiftString($0.key)): \(swiftString($0.value))" }.joined(separator: ", ") + "]")
    }
    if p.music != LaunchProps.Music() {
        args.append("music: .init(bpm: \(Int(p.music.bpm)), key: \(p.music.key), mood: .\(p.music.mood.rawValue))")
    }
    if !p.shots.isEmpty {
        args.append("shots: [" + p.shots.map { o in
            ".init(id: \(swiftString(o.id))" + (o.bars.map { ", bars: \($0)" } ?? "") + (o.hidden.map { ", hidden: \($0)" } ?? "") + ")"
        }.joined(separator: ", ") + "]")
    }
    let closePad = String(repeating: " ", count: indent)
    return "LaunchProps(\n" + args.map { pad + $0 }.joined(separator: ",\n") + "\n\(closePad))"
}

private func snippetLiteral(_ c: LaunchProps.CodeSnippet, pad: String) -> String {
    var a: [String] = []
    // SceneRegistryPlugin scans source text, so a snippet's `public struct X: …Scene`
    // would register X. `public\u{20}` keeps the value and hides it from the scan.
    func hide(_ s: String) -> String { s.replacingOccurrences(of: "public ", with: "public\\u{20}") }
    if c.source.contains("\n") {
        let escaped = c.source.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"\"\"", with: "\\\"\"\"")
        let body = hide(escaped).components(separatedBy: "\n").map { $0.isEmpty ? "" : pad + "    " + $0 }.joined(separator: "\n")
        a.append("source: \"\"\"\n\(body)\n\(pad)    \"\"\"")
    } else {
        a.append("source: \(hide(swiftString(c.source)))")
    }
    if c.language != .swift { a.append("language: .\(c.language.rawValue)") }
    if let t = c.title { a.append("title: \(swiftString(t))") }
    if let f = c.focus { a.append("focus: [\(f.map(String.init).joined(separator: ", "))]") }
    if let cap = c.caption { a.append("caption: \(swiftString(cap))") }
    return ".init(" + a.joined(separator: ", ") + ")"
}

/// A Swift string literal (escaped).
func swiftString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out + "\""
}

/// "swift-render" → "SwiftRender", "my app 2" → "MyApp2".
func swiftTypeName(_ name: String) -> String {
    let parts = name.split { !($0.isLetter || $0.isNumber) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    var s = parts.joined()
    if s.isEmpty { s = "App" }
    if s.first!.isNumber { s = "App" + s }
    return s
}

private func lowerCamel(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

private func fileSafe(_ s: String) -> String {
    let t = s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
    return String(t).trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "launch" : String(t)
}

private func relative(_ url: URL, to base: URL) -> String {
    let p = url.standardizedFileURL.path, b = base.standardizedFileURL.path
    if p == b { return "." }
    return p.hasPrefix(b + "/") ? String(p.dropFirst(b.count + 1)) : p
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try enc.encode(value).write(to: url)
}
