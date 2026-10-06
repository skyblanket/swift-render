import AppKit
import SwiftUI
import XCTest
@testable import SwiftRender
@testable import SwiftRenderKit
@testable import SwiftRenderTool

@MainActor
final class LaunchTests: XCTestCase {
    // MARK: Props

    func testEmptyJSONDecodesToFallback() throws {
        let p = try JSONDecoder().decode(LaunchProps.self, from: Data("{}".utf8))
        XCTAssertEqual(p, LaunchProps.fallback)
    }

    func testLenientDecodingDropsBadPiecesInsteadOfFailing() throws {
        let json = """
        {"name": "Halo", "kind": "game", "accent": 42,
         "features": ["Fast", {"title": "Private", "symbol": "lock.fill"}, {"nope": 1}],
         "platforms": ["iOS", "Mars", {"name": "macOS", "minimum": "14"}],
         "icon": "art/icon.png", "cta": "downloadForMac",
         "music": {"bpm": 128}, "shots": [{"id": "stats", "hidden": true}]}
        """
        let p = try JSONDecoder().decode(LaunchProps.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "Halo")
        XCTAssertEqual(p.kind, .app, "unknown enum value falls back")
        XCTAssertEqual(p.accent, LaunchProps.fallback.accent, "wrong type falls back")
        XCTAssertEqual(p.features.map(\.title), ["Fast", "Private"])
        XCTAssertEqual(p.features[1].symbol, "lock.fill")
        XCTAssertEqual(p.platforms, [.init(.iOS), .init(.macOS, minimum: "14")])
        XCTAssertEqual(p.icon?.path, "art/icon.png")
        XCTAssertEqual(p.cta.kind, .downloadForMac)
        XCTAssertEqual(p.music.bpm, 128)
        XCTAssertEqual(p.validated().props.music.bpm, 120, "validation snaps to a frame-exact tempo")
    }

    func testSampleRoundTrips() throws {
        let data = try JSONEncoder().encode(LaunchProps.sample)
        XCTAssertEqual(try JSONDecoder().decode(LaunchProps.self, from: data), LaunchProps.sample)
    }

    func testValidationSplitsLongTaglineAndFixesContrast() {
        var p = LaunchProps(name: "  X  ", tagline: "Render beautiful launch films from any Swift codebase. It scans your repo and does the rest.",
                            accent: "#101018")
        p.features = [.init(title: "One"), .init(title: "Two")]
        p.changelog = [.init(.added, "Three things"), .init(.fixed, "A bug")]
        let (v, warnings) = p.validated()
        XCTAssertEqual(v.name, "X")
        XCTAssertEqual(v.tagline, "Render beautiful launch films from any Swift codebase.")
        XCTAssertEqual(v.subtitle, "It scans your repo and does the rest.")
        XCTAssertGreaterThanOrEqual(LaunchColor.contrast(v.accent, "#030304"), 3)
        XCTAssertEqual(v.features.map(\.title), ["One", "Two", "Three things"], "pads features from Added items")
        XCTAssertFalse(warnings.isEmpty)
    }

    func testTrimCodeWrapsLongLinesAndClosesBraces() {
        let long = "    let p = Ease.spring(t, from: 0, to: 1, response: 0.5, dampingFraction: 0.6, initialVelocity: 0)"
        let (wrapped, cut) = LaunchText.trimCode(long, maxLines: 16, maxColumns: 60)
        XCTAssertTrue(cut)
        XCTAssertTrue(wrapped.split(separator: "\n").allSatisfy { $0.count <= 60 })
        XCTAssertEqual(wrapped.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""),
                       long.replacingOccurrences(of: " ", with: ""), "wrapping keeps every token")

        let body = (1...30).map { "        let v\($0) = \($0)" }.joined(separator: "\n")
        let (trimmed, _) = LaunchText.trimCode("struct A {\n    func f() {\n\(body)\n    }\n}", maxLines: 10, maxColumns: 80)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertLessThanOrEqual(lines.count, 10)
        XCTAssertEqual(trimmed.filter { $0 == "{" }.count, trimmed.filter { $0 == "}" }.count, "braces stay balanced")
    }

    func testFeatureSymbolsMatchWordsNotSubstrings() {
        XCTAssertEqual(LaunchText.symbol(for: "Springs"), "wand.and.stars")
        XCTAssertEqual(LaunchText.symbol(for: "Progress rings"), "circle.circle")
        XCTAssertEqual(LaunchText.symbol(for: "On-device"), "lock.fill")
        XCTAssertEqual(LaunchText.symbol(for: "Air quality"), "sparkle", "two-letter keys need the whole word")
        XCTAssertEqual(LaunchText.symbol(for: "AI summaries"), "sparkles")
    }

    // MARK: Plan

    func testPlanCutsLandOnFramesAndBeats() {
        for bpm in [90.0, 100.0, 120.0] {
            var p = LaunchProps.sample
            p.music.bpm = bpm
            let plan = LaunchPlan(p)
            for s in plan.starts + [plan.duration] {
                let frames = s * 60
                XCTAssertEqual(frames, frames.rounded(), accuracy: 1e-9, "cut at \(s)s is not on a 60 fps frame (\(bpm) BPM)")
                let beats = s / plan.beat
                XCTAssertEqual(beats, beats.rounded(), accuracy: 1e-6, "cut at \(s)s is off the beat")
            }
        }
        XCTAssertEqual(LaunchPlan.frameExactBPM(128), 120)
        XCTAssertEqual(LaunchPlan.frameExactBPM(95), 90)
    }

    func testPlanAdaptsToProps() {
        var p = LaunchProps(name: "Lib", tagline: "Tiny.", kind: .library)
        XCTAssertEqual(LaunchPlan(p).shots.map(\.kind), [.open, .hero, .title, .end])
        p.features = (1...4).map { .init(title: "F\($0)") }
        p.code = .init(source: "let x = 1")
        p.terminal = ["$ swift build"]
        p.highlights = [.init(value: 120, label: "tests")]
        p.facts = ["Zero dependencies"]
        let plan = LaunchPlan(p)
        XCTAssertEqual(plan.shots.map(\.kind), [.open, .hero, .title, .triad, .code, .terminal, .stats, .platforms, .end],
                       "four features fit the triad; libraries lead with code")
        p.features.append(.init(title: "F5"))
        XCTAssertTrue(LaunchPlan(p).shots.contains { $0.kind == .more })
        XCTAssertGreaterThan(LaunchPlan(p).duration, plan.duration, "length follows content")

        p.shots = [.init(id: "stats", hidden: true), .init(id: "triad", bars: 3), .init(id: "end", hidden: true)]
        let o = LaunchPlan(p)
        XCTAssertFalse(o.shots.contains { $0.kind == .stats })
        XCTAssertEqual(o.shots.first { $0.kind == .triad }?.bars, 3)
        XCTAssertTrue(o.shots.contains { $0.kind == .end }, "the end card can't be hidden")
        let hit = o.shot(at: o.start(.triad)! + 0.5)
        XCTAssertEqual(hit?.shot.kind, .triad)
        XCTAssertEqual(hit?.local ?? 0, 0.5, accuracy: 1e-9)
    }

    // MARK: Score

    func testScoreFollowsHouseRules() {
        let p = LaunchProps.sample
        let plan = LaunchPlan(p)
        let score = LaunchScore.make(plan, p)
        XCTAssertEqual(score.duration, plan.duration)
        for e in score.events {
            switch e.sound {
            case .whoosh, .riser, .crash, .boom: XCTFail("forbidden sound \(e.sound) at \(e.time)")
            default: break
            }
        }
        let thumps = score.events.filter { if case .thump = $0.sound { return true }; return false }.map(\.time)
        XCTAssertTrue(thumps.contains { abs($0 - plan.start(.hero)!) < 1e-9 })
        XCTAssertTrue(thumps.contains { abs($0 - plan.start(.end)!) < 1e-9 })
        XCTAssertFalse(score.events.contains { if case .speech = $0.sound { return true }; return false })

        var vo = p
        vo.voiceover = true
        vo.voiceoverLines = ["end": "Lumen. Out now."]
        let lines = LaunchScore.voiceoverLines(plan, vo)
        XCTAssertEqual(lines.first?.text, "Introducing Lumen.")
        XCTAssertEqual(lines.last?.text, "Lumen. Out now.")
        XCTAssertEqual(lines.last?.time ?? 0, plan.start(.end)! + 0.3, accuracy: 1e-9)
    }

    // MARK: Highlighter

    func testSwiftHighlighter() {
        let src = "@MainActor struct A: View { // hi\n    let s = \"x \\\"y\\\"\"; var n = 0x1F\n    func f() { Text(s).font(.title) }\n}"
        let lines = SwiftHighlighter.tokenize(src)
        XCTAssertEqual(lines.map { $0.map(\.text).joined() }, src.components(separatedBy: "\n"), "tokens reproduce the source")
        let flat = lines.flatMap { $0 }
        func kind(_ text: String) -> SwiftHighlighter.Kind? { flat.first { $0.text == text }?.kind }
        XCTAssertEqual(kind("@MainActor"), .attribute)
        XCTAssertEqual(kind("struct"), .keyword)
        XCTAssertEqual(kind("View"), .type)
        XCTAssertEqual(kind("// hi"), .comment)
        XCTAssertEqual(kind("\"x \\\"y\\\"\""), .string)
        XCTAssertEqual(kind("0x1F"), .number)
        XCTAssertEqual(kind("font"), .call)
    }

    // MARK: Scanner

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-launch-\(UUID().uuidString)")
        func write(_ rel: String, _ s: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try s.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Package.swift", """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "TinyKit", platforms: [.iOS(.v17), .macOS(.v14)],
            products: [.library(name: "TinyKit", targets: ["TinyKit"])], targets: [.target(name: "TinyKit")])
        """)
        try write("README.md", """
        <div align="center">

        # TinyKit

        ![badge](https://img.shields.io/badge/x-y-blue?color=FF2D55)

        **Small, fast layout helpers for SwiftUI.** No dependencies, ever.

        </div>

        ## Install

        ```swift
        .package(url: "https://github.com/acme/TinyKit", from: "1.0.0")
        ```

        ## Features

        - **Fast** — layout in a single pass.
        - **Private API free**: only public SwiftUI.
        - **Tiny** — under 500 lines.

        ## Usage

        ```swift
        import SwiftUI
        import TinyKit

        struct Demo: View {
            var body: some View { Grid2 { Text("Hi") } }
        }
        ```
        """)
        try write("CHANGELOG.md", """
        # Changelog
        ## Unreleased
        - nothing yet
        ## [1.1.0] — 2026-08-01
        ### Fixed
        - Crash on empty grids.
        ### Added
        - **Grid2** — a two-column grid.
          Wraps automatically.
        """)
        try write("Sources/TinyKit/Grid2.swift", "public struct Grid2 {}\n// comment\n\nlet x = 1\n")
        try write("Tests/TinyKitTests/T.swift", "func testA() {}\nfunc testB() {}\n@Test func c() {}\n")
        try write("LICENSE", "MIT License\nPermission is hereby granted, free of charge")
        try write("Assets.xcassets/AccentColor.colorset/Contents.json", """
        {"colors":[{"color":{"color-space":"srgb","components":{"red":"0.000","green":"0.478","blue":"1.000","alpha":"1"}},"idiom":"universal"}]}
        """)
        return root
    }

    func testScannerReadsACodebase() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (p, report) = LaunchScanner(root: root, options: .init(executeManifest: false, git: false)).scan()
        XCTAssertEqual(p.name, "TinyKit")
        XCTAssertEqual(p.kind, .library)
        XCTAssertEqual(p.tagline, "Small, fast layout helpers for SwiftUI.")
        XCTAssertEqual(p.subtitle, "No dependencies, ever.")
        XCTAssertEqual(p.features.map(\.title), ["Fast", "Private API free", "Tiny"])
        XCTAssertEqual(p.features[0].detail, "Layout in a single pass.")
        XCTAssertEqual(p.features[0].symbol, "bolt.fill")
        XCTAssertEqual(p.platforms, [.init(.iOS, minimum: "17"), .init(.macOS, minimum: "14")])
        XCTAssertEqual(p.swiftVersion, "5.9")
        XCTAssertEqual(p.version, "1.1.0")
        XCTAssertEqual(p.releaseDate, "2026-08-01")
        XCTAssertEqual(p.changelog.first, .init(.added, "Grid2"), "Added ranks above Fixed; bold lead-in is the title")
        XCTAssertEqual(p.accent, "#007AFF", "AccentColor beats the README badge")
        XCTAssertEqual(p.license, "MIT")
        XCTAssertEqual(p.code?.title, "Demo.swift")
        XCTAssertFalse(p.code?.source.contains("import TinyKit") ?? true, "extra imports are dropped")
        XCTAssertEqual(p.install?.source, ".package(url: \"https://github.com/acme/TinyKit\", from: \"1.0.0\")")
        XCTAssertEqual(p.stats.testCount, 3)
        XCTAssertEqual(p.stats.dependencies, 0)
        XCTAssertEqual(p.facts.first, "Zero dependencies")
        XCTAssertTrue(p.highlights.isEmpty, "small numbers are never highlighted")
        XCTAssertEqual(report.source(of: "tagline"), "README.md:7")
        XCTAssertTrue(report.missing.contains { $0.hasPrefix("git") })
    }

    func testScannerNeverFailsOnAnEmptyFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (p, report) = LaunchScanner(root: root, options: .init(executeManifest: false, git: false)).scan()
        XCTAssertEqual(p.name, root.lastPathComponent)
        XCTAssertFalse(p.tagline.isEmpty)
        XCTAssertFalse(report.missing.isEmpty)
        XCTAssertGreaterThan(LaunchPlan(p).duration, 0)
    }

    func testGitHubURLNormalization() {
        XCTAssertEqual(LaunchScanner.githubURL("git@github.com:acme/tiny.git")?.0, "https://github.com/acme/tiny")
        XCTAssertEqual(LaunchScanner.githubURL("https://github.com/acme/tiny.git")?.1, "acme/tiny")
        XCTAssertNil(LaunchScanner.githubURL("/local/path"))
    }

    // MARK: CLI helpers

    func testSwiftLiteralHelpers() {
        XCTAssertEqual(swiftTypeName("swift-render"), "SwiftRender")
        XCTAssertEqual(swiftTypeName("3d viewer"), "App3dViewer")
        XCTAssertEqual(swiftString("a \"b\"\n\\"), "\"a \\\"b\\\"\\n\\\\\"")
        let lit = propsLiteral(.sample, indent: 4)
        XCTAssertTrue(lit.hasPrefix("LaunchProps(\n"))
        XCTAssertTrue(lit.contains("source: \"\"\""), "multi-line code becomes a multi-line string")
        XCTAssertTrue(lit.contains(".init(.downloadForMac)"))
    }

    // MARK: Rendering

    private func luminanceSpread(_ url: URL) throws -> Double {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        var values: [Double] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                let c = rep.colorAt(x: x, y: y)!
                values.append(0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    func testEveryShotRendersAtBothAspects() throws {
        var p = LaunchProps.sample
        p.screenshots = [.init(path: "missing.png")]   // placeholder screen, still a device shot
        let plan = LaunchPlan(p)
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            let recorder = Recorder(config: .init(fps: 30, size: size, scale: 0.15))
            for (i, shot) in plan.shots.enumerated() {
                let t = plan.starts[i] + plan.length(i) * 0.75
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(shot.id)-\(Int(size.width)).png")
                try recorder.renderPNG(at: t, to: url, postFX: false, duration: plan.duration) { tt in
                    AppleLaunch.body(at: tt, duration: plan.duration, props: p)
                }
                XCTAssertGreaterThan(try luminanceSpread(url), 0.01, "\(shot.id) at \(size) looks blank")
            }
        }
    }
}
