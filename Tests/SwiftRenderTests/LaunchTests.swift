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

    func testHelperAppInfoPlistDoesNotRenameALibrary() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // A library repo that also packages a helper .app (swift-render's own Support/Studio/Info.plist).
        let plist = root.appendingPathComponent("Support/Viewer/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "TinyKit Viewer"], format: .xml, options: 0)
            .write(to: plist)
        let (p, report) = LaunchScanner(root: root, options: .init(executeManifest: false, git: false)).scan()
        XCTAssertEqual(p.name, "TinyKit")
        XCTAssertEqual(report.source(of: "name"), "Package.swift")
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
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080)] {
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

    // MARK: Regressions (0.10 review)

    private func write(_ root: URL, _ rel: String, _ s: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    private func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func scan(_ root: URL) -> (LaunchProps, LaunchScanReport) {
        LaunchScanner(root: root, options: .init(executeManifest: false, git: false)).scan()
    }

    func testScannerFollowsASymlinkedRoot() throws {
        let root = try fixture()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("sr-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: link) }
        let (p, report) = scan(link)
        XCTAssertEqual(p.tagline, "Small, fast layout helpers for SwiftUI.", "the README is found through the link")
        XCTAssertEqual(p.features.count, 3)
        XCTAssertFalse(report.missing.contains { $0.hasPrefix("README") })
    }

    func testFileCapNeverHidesTopLevelFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // A data folder that sorts (and, on APFS, often enumerates) before the README.
        for i in 0..<60 { try write(root, "AAAData/\(i).json", "{}") }
        let (p, report) = LaunchScanner(root: root, options: .init(executeManifest: false, git: false, maxFiles: 20)).scan()
        XCTAssertTrue(report.warnings.contains { $0.contains("stopped after 20 files") })
        XCTAssertEqual(p.tagline, "Small, fast layout helpers for SwiftUI.")
        XCTAssertEqual(p.license, "MIT")
        XCTAssertEqual(p.version, "1.1.0")
        XCTAssertEqual(p.accent, "#007AFF", "shallow manifests (depth 1) come before deep files")
    }

    func testScannerConfinesIconPathsAndSurvivesCorruptMetadata() throws {
        let root = try tempDir("icons")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try write(root, "secret.txt", "TOP-SECRET")
        try write(repo, "App/Assets.xcassets/AppIcon.appiconset/Contents.json", """
        {"images":[{"filename":"../../../../secret.txt","idiom":"universal","size":"1024x1024"},
                   {"filename":"inf.png","idiom":"universal","size":"1e200x1e200"},
                   {"filename":"nan.png","idiom":"universal","size":"nanxnan","scale":"2x"},
                   {"filename":"huge.png","idiom":"universal","size":"20x20"}]}
        """)
        // A PNG header claiming 0xFFFFFFFF × 0xFFFFFFFF: w × h used to overflow and trap.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        for name in ["inf.png", "nan.png", "huge.png"] {
            try png.write(to: repo.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/\(name)"))
        }
        let (p, report) = scan(repo)
        XCTAssertFalse(p.icon?.path.contains("..") ?? false, "an icon filename can't leave its icon set")
        XCTAssertTrue(report.warnings.contains { $0.contains("secret.txt") })
        XCTAssertNil(LaunchScanner.contained("../secret.txt", in: repo))
        XCTAssertNil(LaunchScanner.contained(root.appendingPathComponent("secret.txt").path, in: repo))
        XCTAssertNotNil(LaunchScanner.contained("App/Assets.xcassets", in: repo))
    }

    func testScannerReadsCRLFReadmesAndGitHubScreenshots() throws {
        let root = try tempDir("crlf")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "README.md", "# Demo\r\n\r\nA tiny demo app for testing.\r\n\r\n## Usage\r\n\r\n```swift\r\nstruct Hello: View {\r\n    var body: some View { Text(\"Hi\") }\r\n}\r\n```\r\n")
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 0x05, 0x0A, 0, 0, 0x0A, 0xEC])   // 1290 × 2796
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/screenshots"), withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent(".github/screenshots/home.png"))
        let (p, _) = scan(root)
        XCTAssertEqual(p.tagline, "A tiny demo app for testing.")
        XCTAssertEqual(p.code?.title, "Hello.swift")
        XCTAssertEqual(p.screenshots.map(\.path), [".github/screenshots/home.png"])
        XCTAssertEqual(p.screenshots.first?.device, .iPhone)
    }

    func testSwiftPMAppsAreApps() throws {
        func package(_ products: String) throws -> URL {
            let root = try tempDir("spmapp")
            try write(root, "Package.swift", """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "Tidepool", platforms: [.iOS(.v17), .macOS(.v14)],
                products: [\(products)],
                targets: [.target(name: "TidepoolKit"), .executableTarget(name: "Tidepool", dependencies: ["TidepoolKit"]),
                          .executableTarget(name: "TidepoolViewer")])
            """)
            let app = "import SwiftUI\n@main struct TidepoolApp: App {\n    var body: some Scene { WindowGroup { Text(\"Hi\") } }\n}\n"
            try write(root, "Sources/Tidepool/TidepoolApp.swift", app)
            try write(root, "Sources/TidepoolViewer/ViewerApp.swift", app.replacingOccurrences(of: "TidepoolApp", with: "ViewerApp"))
            try write(root, "Sources/TidepoolKit/Habit.swift", "public struct Habit {}\n")
            return root
        }
        let both = try package(#".library(name: "TidepoolKit", targets: ["TidepoolKit"]), .executable(name: "Tidepool", targets: ["Tidepool"])"#)
        let exe = try package(#".executable(name: "Tidepool", targets: ["Tidepool"])"#)
        let aux = try package(#".library(name: "Tidepool", targets: ["TidepoolKit"]), .executable(name: "tidepool-viewer", targets: ["TidepoolViewer"])"#)
        defer { for u in [both, exe, aux] { try? FileManager.default.removeItem(at: u) } }
        // In the auxiliary case only the viewer is an App.
        try FileManager.default.removeItem(at: aux.appendingPathComponent("Sources/Tidepool/TidepoolApp.swift"))

        let (p1, r1) = scan(both)
        XCTAssertEqual(p1.kind, .app, "library + an @main App executable named like the package")
        XCTAssertEqual(r1.source(of: "kind")?.hasPrefix("Sources/Tidepool/TidepoolApp.swift"), true)
        XCTAssertEqual(p1.cta.kind, .appStore)
        XCTAssertEqual(scan(exe).0.kind, .app, "an @main App executable alone is an app, not a CLI")
        XCTAssertEqual(scan(aux).0.kind, .library, "an auxiliary App beside a library (swift-render's Studio) stays a library")
    }

    func testRescanIgnoresTheInitScaffold() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = scan(root).0.stats.swiftLines
        try write(root, "Launch/swift-render.json", "{}")
        try write(root, "Launch/Sources/LaunchScenes/TinyKitLaunch.swift", (1...200).map { "let v\($0) = \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(scan(root).0.stats.swiftLines, before, "the launch film's code isn't the product's")
    }

    func testInitNeverClobbersAndKeepsEditedProps() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent).png")); try? FileManager.default.removeItem(at: root) }
        // An unrelated Launch/ folder (a launch-screen module) must survive.
        try write(root, "Launch/README.md", "Team notes: do not touch.")
        try write(root, "Launch/.gitignore", "secrets.plist\n")
        XCTAssertThrowsError(try runInit([root.path, "--no-manifest"])) { e in
            XCTAssertTrue("\(e)".contains("Launch/README.md"), "\(e)")
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Launch/.gitignore"), encoding: .utf8), "secrets.plist\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Launch/Package.swift").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Launch"))

        // Props kept by `launch` (edited) win over the scan; an asset path out of the repo is not copied.
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent).png")
        try Data("SECRET".utf8).write(to: outside)
        var edited = scan(root).0
        edited.tagline = "Edited tagline."
        edited.icon = .init(path: "../" + outside.lastPathComponent)
        try write(root, ".swift-render/launch/TinyKit.json", String(decoding: try JSONEncoder().encode(edited), as: UTF8.self))
        try runInit([root.path, "--no-manifest"])
        let scene = try String(contentsOf: root.appendingPathComponent("Launch/Sources/LaunchScenes/TinyKitLaunch.swift"), encoding: .utf8)
        XCTAssertTrue(scene.contains("tagline: \"Edited tagline.\""))
        XCTAssertTrue(scene.contains(".named(s.id)"), "scaffolded clips are named by shot")
        let assets = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Launch/assets").path)
        XCTAssertTrue(assets.isEmpty, "nothing from outside the repo is copied: \(assets)")

        XCTAssertThrowsError(try runInit([root.path, "--no-manifest"]), "a second init refuses without --force")
        try runInit([root.path, "--no-manifest", "--force", "--rescan"])
        let rescanned = try String(contentsOf: root.appendingPathComponent("Launch/Sources/LaunchScenes/TinyKitLaunch.swift"), encoding: .utf8)
        XCTAssertTrue(rescanned.contains("tagline: \"Small, fast layout helpers for SwiftUI.\""))
    }

    func testBalanceKeepsHeadlineLinesEven() {
        let lines = AppleLaunchShot.balance("Plan every trail, campsite and summit, even offline.")
        XCTAssertEqual(lines.count, 2)
        let (a, b) = (Double(lines[0].count), Double(lines[1].count))
        XCTAssertLessThanOrEqual(max(a, b), 1.5 * min(a, b), "\(lines)")
        XCTAssertEqual(AppleLaunchShot.balance("Fast, predictable data structures for Swift."),
                       ["Fast, predictable data", "structures for Swift."])
        XCTAssertEqual(AppleLaunchShot.balance("Notes that think with you."), ["Notes that", "think with you."])
        XCTAssertEqual(AppleLaunchShot.balance("Small and quick, yet powerful and safe."), ["Small and quick,", "yet powerful and safe."],
                       "an even comma break still wins")
    }

    func testHeadlineLinesShareOneSize() {
        let theme = LaunchTheme(props: .sample)
        let lines = ["Plan every trail,", "campsite and summit, even offline."]
        let width: CGFloat = 1080 * 0.84
        let s = theme.fittedDisplaySize(lines, size: 128 * 1.75 * 1080 / 1920, width: width)
        XCTAssertLessThan(s, 126, "the long line needs a smaller size")
        XCTAssertLessThanOrEqual(lines.map { theme.displayWidth($0, size: s) }.max()!, width)
        XCTAssertGreaterThan(theme.displayWidth(lines[1], size: s), width * 0.9, "…and gets the largest one that fits")
        XCTAssertEqual(theme.fittedDisplaySize(["Hi"], size: 120, width: 1000), 120, "short lines keep the authored size")
        XCTAssertEqual(KeynoteTitle.lineStart(0, start: 0), 0, "the first line moves from the cut")
    }

    func testTerminalShotFitsItsSession() {
        var p = LaunchProps.sample
        XCTAssertEqual(LaunchPlan(p).shots.first { $0.kind == .terminal }?.bars, 2, "a short session keeps 2 bars")
        p.terminal = ["$ swift package add-dependency https://github.com/example/swift-collections-extended", "Updating Package.swift",
                      "$ swift build --configuration release --product Benchmarks", "Compiling 42 files", "✓ Build complete",
                      "$ swift run Benchmarks --filter OrderedSet", "OrderedSet.insert   1.2 ns/op"]
        for bpm in [90.0, 100.0, 120.0] {
            p.music.bpm = bpm
            let v = p.validated().props
            let plan = LaunchPlan(v)
            let i = plan.index(of: .terminal)!
            XCTAssertGreaterThan(plan.shots[i].bars, 2)
            XCTAssertLessThanOrEqual(plan.shots[i].bars, 4)
            let cps = LaunchScore.Cue.terminalSpeed(plan, v)
            let end = LaunchTerminal.end(v.terminal!, cps: cps)
            XCTAssertLessThanOrEqual(end, plan.length(i) - LaunchTerminal.hold + 1e-9, "\(bpm) BPM: the last command finishes before the cut")
            let lines = TerminalCard.session(v.terminal!, start: LaunchScore.Cue.terminalStart, cps: cps)
            XCTAssertEqual(lines.map(\.text).last, "OrderedSet.insert   1.2 ns/op")
            // The score types at the same speed the picture does.
            let ticks = LaunchScore.make(plan, v).events.filter { if case .tick = $0.sound { return true }; return false }
                .map(\.time).filter { $0 >= plan.starts[i] && $0 < plan.starts[i] + plan.length(i) }
            XCTAssertEqual(ticks.max() ?? 0, plan.starts[i] + TerminalCard.keystrokeTimes(lines, cps: cps, every: max(2, Int(cps / 13))).max()!,
                           accuracy: 1e-9)
        }
        // A transcript that can't fit is cut down (with a warning), not cut off mid-keystroke.
        p.terminal = (1...6).flatMap { ["$ make target\($0)", "a", "b", "c", "d"] }
        let (v, w) = p.validated()
        XCTAssertEqual(v.terminal?.filter { $0.hasPrefix("$ ") }.count, 2)
        XCTAssertLessThanOrEqual(v.terminal?.count ?? 0, 8)
        XCTAssertTrue(w.contains { $0.hasPrefix("terminal:") })
    }

    func testTerminalCardFitsTheLongestLine() {
        let lines = TerminalCard.session(LaunchProps.sample.terminal!)
        let width: CGFloat = 1080 * 0.84
        let fs = TerminalCard.fittedFontSize(lines, prompt: "$ ", width: width, padding: 32, fontSize: 28, floor: 18)
        let longest = lines.map(\.text.count).max()!
        XCTAssertLessThanOrEqual(CGFloat(longest) * fs * 0.6, width - 64, "the 9:16 sample's Pouring line fits")
        XCTAssertEqual(TerminalCard.fittedFontSize(lines, prompt: "$ ", width: 1360, padding: 32, fontSize: 34, floor: 18), 34)
    }

    func testHeroHitsFollowTheTempo() {
        for bpm in [90.0, 100.0, 120.0] {
            var p = LaunchProps.sample
            p.music.bpm = bpm
            let plan = LaunchPlan(p)
            let s0 = plan.start(.hero)!
            let events = LaunchScore.make(plan, p).events
            let blips = events.filter { if case .blip = $0.sound { return true }; return false }.map(\.time)
            let bells = events.filter { if case .bell = $0.sound { return true }; return false }.map(\.time)
            XCTAssertTrue(blips.contains { abs($0 - (s0 + LaunchScore.Cue.heroSweep(plan))) < 1e-9 }, "\(bpm) BPM sweep blip")
            XCTAssertTrue(bells.contains { abs($0 - (s0 + LaunchScore.Cue.heroName(plan))) < 1e-9 }, "\(bpm) BPM name bell")
            XCTAssertEqual(LaunchScore.Cue.heroSweep(plan), plan.beat * 2 - 0.2, accuracy: 1e-12)
        }
    }

    func testSquareCanvasStacks() {
        let sq = LaunchLayout(RenderContext(size: CGSize(width: 1080, height: 1080), fps: 60))
        XCTAssertTrue(sq.stacks)
        XCTAssertFalse(sq.isVertical)
        XCTAssertGreaterThan(sq.type, 0.7, "not a 56% copy of the 16:9 film")
        XCTAssertFalse(LaunchLayout(RenderContext(size: CGSize(width: 1920, height: 1080), fps: 60)).stacks)
        XCTAssertTrue(LaunchLayout(RenderContext(size: CGSize(width: 1080, height: 1920), fps: 60)).stacks)
    }

    /// Every shot is already moving a tenth of a second after its cut — no dead stage under the downbeat hit.
    func testShotsAreOnScreenRightAfterTheirCuts() throws {
        let p = LaunchProps.sample
        let plan = LaunchPlan(p)
        let recorder = Recorder(config: .init(fps: 60, size: CGSize(width: 1920, height: 1080), scale: 0.25))
        for (i, shot) in plan.shots.enumerated() where i > 0 && shot.kind != .end {
            let t = plan.starts[i] + 6.0 / 60
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-cut-\(shot.id).png")
            try recorder.renderPNG(at: t, to: url, postFX: false, duration: plan.duration) { tt in
                AppleLaunch.body(at: tt, duration: plan.duration, props: p)
            }
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            var lum: [Double] = []
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    let c = rep.colorAt(x: x, y: y)!
                    lum.append(0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
                }
            }
            lum.sort()
            XCTAssertGreaterThan(lum[Int(Double(lum.count) * 0.999)], 0.2, "\(shot.id): bare stage 0.1 s after the cut")
        }
    }

    func testValidationKeepsFeatureDetailsToTheirContract() {
        var p = LaunchProps(name: "X")
        p.features = [.init(title: "A", detail: String(repeating: "word ", count: 30))]
        XCTAssertLessThanOrEqual(p.validated().props.features[0].detail.count, 80)
    }
}
