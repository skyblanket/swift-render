import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// A build runner the test drives by hand: each `start` hands back a continuation.
final class ScriptedBuilds: @unchecked Sendable {
    private let lock = NSLock()
    private var conts: [AsyncStream<BuildUpdate>.Continuation] = []
    var started: Int { lock.withLock { conts.count } }

    var runner: BuildController.Runner {
        { _, _, _ in
            let (s, c) = AsyncStream.makeStream(of: BuildUpdate.self)
            self.lock.withLock { self.conts.append(c) }
            return (s, { c.finish() })
        }
    }

    func send(_ i: Int, _ e: BuildUpdate) { lock.withLock { conts[i] }.yield(e) }
    func finish(_ i: Int, success: Bool, diagnostics: [CompilerDiagnostic] = [], log: String = "") {
        let c = lock.withLock { conts[i] }
        c.yield(.finished(.init(success: success, seconds: 1.25, diagnostics: diagnostics, log: log,
                                executable: success ? URL(fileURLWithPath: "/tmp/bin/swift-render") : nil)))
        c.finish()
    }
}

@MainActor
final class BuildControllerTests: XCTestCase {
    let project = Project(root: URL(fileURLWithPath: "/tmp/Proj"))

    func testScratchPathAndProgress() {
        let b = BuildController(project: project, runner: ScriptedBuilds().runner)
        XCTAssertEqual(b.scratchPath.path, "/tmp/Proj/.build/studio")      // nonexistent: left as is
        let real = BuildController(project: Project(root: URL(fileURLWithPath: "/tmp")), runner: ScriptedBuilds().runner)
        XCTAssertEqual(real.scratchPath.path, "/private/tmp/.build/studio", "same spelling as getcwd() in a terminal")
        XCTAssertEqual(b.product, "swift-render")
        XCTAssertTrue(BuildController.parseProgress("[12/40] Compiling SwiftRender NeverHeard.swift")! == (12, 40))
        XCTAssertNil(BuildController.parseProgress("Building for debugging..."))
        XCTAssertNil(BuildController.parseProgress("[x/40] nope"))
    }

    func testChangesMidBuildCoalesceIntoOneRebuild() async {
        let builds = ScriptedBuilds()
        let b = BuildController(project: project, runner: builds.runner)
        var succeeded: [Int] = []
        b.onSuccess = { _, gen in succeeded.append(gen) }

        b.requestBuild(.initial)
        XCTAssertEqual(builds.started, 1)
        builds.send(0, .progress("[3/10] Compiling SwiftRender A.swift"))
        await waitUntil(2, "progress") { b.progress?.done == 3 }
        XCTAssertEqual(b.phase, .building("[3/10] Compiling SwiftRender A.swift"))

        // Three saves land while building: one pending rebuild, no concurrent build.
        for _ in 0..<3 { b.requestBuild(.sourceChange(["Sources/A.swift"])) }
        XCTAssertEqual(builds.started, 1)
        XCTAssertTrue(b.pendingRebuild)

        builds.finish(0, success: true)
        await waitUntil(2, "rebuild starts") { builds.started == 2 }
        XCTAssertEqual(succeeded, [1])
        XCTAssertFalse(b.pendingRebuild)

        builds.finish(1, success: true)
        await waitUntil(2, "second success") { succeeded == [1, 2] }
        XCTAssertEqual(builds.started, 2, "exactly one extra build")
        XCTAssertEqual(b.lastGoodExecutable?.path, "/tmp/bin/swift-render")
        if case .succeeded(let s, _) = b.phase { XCTAssertEqual(s, 1.25) } else { XCTFail("\(b.phase)") }
    }

    func testFailureKeepsLastGoodAndListsErrors() async {
        let builds = ScriptedBuilds()
        let b = BuildController(project: project, runner: builds.runner)
        b.requestBuild(.initial)
        builds.finish(0, success: true)
        await waitUntil(2, "first build") { b.generation == 1 }

        b.requestBuild(.manual)
        builds.send(1, .waitingForLock)
        await waitUntil(2, "lock wait") { b.phase == .waitingForLock }
        let err = CompilerDiagnostic(file: "/tmp/Proj/Sources/A.swift", line: 12, column: 14, severity: .error,
                                     message: "cannot convert value of type 'String' to specified type 'Double'")
        let warn = CompilerDiagnostic(file: "/tmp/Proj/Sources/B.swift", line: 3, column: 1, severity: .warning, message: "unused")
        builds.send(1, .diagnostic(err))
        builds.send(1, .diagnostic(err))                          // Swift 6 prints each twice
        builds.send(1, .diagnostic(warn))
        await waitUntil(2, "diagnostics") { b.diagnostics.count == 2 }
        builds.finish(1, success: false, diagnostics: [err, warn], log: "error: build failed")
        await waitUntil(2, "failure") { if case .failed = b.phase { return true }; return false }
        XCTAssertEqual(b.phase, .failed([err], log: "error: build failed"))
        XCTAssertEqual(b.errors, [err])
        XCTAssertEqual(b.warnings, [warn])
        XCTAssertEqual(b.generation, 1, "failed builds don't bump the generation")
        XCTAssertNotNil(b.lastGoodExecutable)
    }

    func testLinkerFailureWithoutDiagnosticsStillHasARow() async {
        let builds = ScriptedBuilds()
        let b = BuildController(project: project, runner: builds.runner)
        b.requestBuild(.initial)
        builds.finish(0, success: false, log: "Linking swift-render\nld: error: undefined symbol _foo\n")
        await waitUntil(2, "failure") { if case .failed = b.phase { return true }; return false }
        guard case .failed(let rows, _) = b.phase else { return }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].message.contains("undefined symbol"))
    }
}

final class FileWatcherTests: XCTestCase {
    func testClassification() {
        let cases: [(String, FileWatcher.Change.Kind?)] = [
            ("Sources/SwiftRender/Scenes/NeverHeard.swift", .source),
            ("Sources/SwiftRender/Shaders/Glow.metal", .source),
            ("Plugins/SceneRegistryPlugin/plugin.swift", .source),
            ("Package.swift", .manifest),
            ("swift-render.json", .manifest),
            ("assets/logo.png", .asset),
            (".swift-render/reviews/NeverHeard.json", .review),
            (".swift-render/knobs/NeverHeard.json", .knobs),
            (".swift-render/attachments/c1-before.png", nil),
            (".swift-render/cache/audio/ab.wav", nil),
            (".build/studio/debug/swift-render", nil),
            ("Sources/A.swift.swp", nil),
            ("Sources/.#A.swift", nil),
            ("Sources/.DS_Store", nil),
            ("out/NeverHeard.mp4", nil),
            ("README.md", nil),
            // Agent worktrees and their build trees, tests, scripts: not this product's sources.
            (".claude/worktrees/wt/.build/plugins/outputs/x/SceneRegistry.swift", nil),
            (".claude/worktrees/wt/.build/debug/X.build/DerivedSources/resource_bundle_accessor.swift", nil),
            (".claude/worktrees/wt/Sources/SwiftRender/Asset.swift", nil),
            (".claude/worktrees/wt/Package.swift", nil),
            ("Sources/Vendored/.build/x.swift", nil),
            ("Sources/Lib/node_modules/a/b.swift", nil),
            ("Tests/SwiftRenderStudioTests/HostTests.swift", nil),
            ("scripts/tool.swift", nil),
            (".vscode/settings.json", nil),
        ]
        for (path, kind) in cases { XCTAssertEqual(FileWatcher.classify(path), kind, path) }
        XCTAssertEqual(FileWatcher.relative("/private/tmp/p/Sources/A.swift", root: "/tmp/p"), "Sources/A.swift")
        XCTAssertNil(FileWatcher.relative("/tmp/other/A.swift", root: "/tmp/p"))
        let c = FileWatcher.coalesce([.review: ["b"], .source: ["z", "a"]])
        XCTAssertEqual(c.map(\.kind), [.source, .review])
        XCTAssertEqual(c[0].paths, ["a", "z"])
    }

    /// Real FSEvents: an atomic save (write temp + rename, like Xcode) of a source
    /// file and a review write arrive as one debounced batch.
    func testFSEventsDeliversDebouncedBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".swift-render/reviews"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let got = expectation(description: "changes")
        let box = ChangesBox()
        let w = FileWatcher(root: root, debounce: .milliseconds(150)) { changes in
            box.append(changes)
            if box.kinds.contains(.source), box.kinds.contains(.review) { got.fulfill() }
        }
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.3)       // FSEvents needs a moment before the first write counts
        try "struct A {}".write(to: root.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "[]".write(to: root.appendingPathComponent(".swift-render/reviews/A.json"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        wait(for: [got], timeout: 5)
        XCTAssertTrue(box.paths.contains("Sources/A.swift"))
        XCTAssertFalse(box.paths.contains("notes.txt"))
        XCTAssertLessThanOrEqual(box.batches, 2, "debounced, not one callback per event")
    }

    private final class ChangesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[FileWatcher.Change]] = []
        func append(_ c: [FileWatcher.Change]) { lock.withLock { all.append(c) } }
        var kinds: Set<FileWatcher.Change.Kind> { lock.withLock { Set(all.joined().map(\.kind)) } }
        var paths: Set<String> { lock.withLock { Set(all.joined().flatMap(\.paths)) } }
        var batches: Int { lock.withLock { all.count } }
    }
}

final class RuntimeDiagnosticsTests: XCTestCase {
    func testParsesFatalErrorAndFirstProjectFrame() {
        let report = """
        Swift/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range

        💣 Program crashed: System trap at 0x000000019a4c1234

        Thread 0 "main" crashed:

        0      0x000000019a4c1234 _assertionFailure(_:_:file:line:flags:) + 176 in libswiftCore.dylib
        1 [ra] 0x0000000100a3f2c8 NeverHeard.panel(_:_:) + 432 in swift-render at /Users/me/proj/Sources/Scenes/NeverHeard.swift:212:14
        2 [ra] 0x0000000100a3e010 NeverHeard.body(at:) + 88 in swift-render at /Users/me/proj/Sources/Scenes/NeverHeard.swift:180:9
        """
        let c = RuntimeDiagnostics.parse(stderr: report, projectRoot: URL(fileURLWithPath: "/Users/me/proj"), signal: 5)
        XCTAssertEqual(c.message, "Fatal error: Index out of range")
        XCTAssertEqual(c.symbol, "NeverHeard.panel(_:_:)")
        XCTAssertEqual(c.location?.file, "/Users/me/proj/Sources/Scenes/NeverHeard.swift")
        XCTAssertEqual(c.location?.line, 212)
        XCTAssertEqual(c.location?.column, 14)
        XCTAssertEqual(c.signal, 5)
    }

    func testFramesOutsideTheProjectAreSkipped() {
        let report = "0 0x01 foo() + 1 in libX.dylib at /usr/lib/x.swift:3\nSegmentation fault"
        let c = RuntimeDiagnostics.parse(stderr: report, projectRoot: URL(fileURLWithPath: "/Users/me/proj"), signal: 11)
        XCTAssertNil(c.location)
        XCTAssertEqual(c.message, "Host crashed (signal 11)")
    }
}

@MainActor
final class KeyRouterTests: XCTestCase {
    typealias S = KeyRouter.Stroke

    func testTypingInATextFieldNeverSeeks() {
        let r = KeyRouter(model: nil)
        for ch in "jkl c io r g [ ] \\ /" {
            XCTAssertNil(r.action(for: S(chars: String(ch)), textEditing: true), "'\(ch)' leaked out of the composer")
        }
        XCTAssertNil(r.action(for: S(chars: " ", keyCode: KeyRouter.KeyCode.space), textEditing: true))
        XCTAssertNil(r.action(for: S(chars: "", keyCode: KeyRouter.KeyCode.left), textEditing: true))
    }

    func testEditingKeys() {
        let r = KeyRouter(model: nil)
        XCTAssertEqual(r.action(for: S(chars: " ", keyCode: KeyRouter.KeyCode.space), textEditing: false), .playPause)
        XCTAssertEqual(r.action(for: S(chars: "", keyCode: KeyRouter.KeyCode.left), textEditing: false), .stepFrames(-1))
        XCTAssertEqual(r.action(for: S(chars: "", keyCode: KeyRouter.KeyCode.right, shift: true), textEditing: false), .stepSeconds(1))
        XCTAssertEqual(r.action(for: S(chars: "", keyCode: KeyRouter.KeyCode.down), textEditing: false), .jumpEdit(next: true))
        XCTAssertEqual(r.action(for: S(chars: "I", shift: true), textEditing: false), .goIn)
        XCTAssertEqual(r.action(for: S(chars: "x", option: true), textEditing: false), .clearInOut)
        XCTAssertNil(r.action(for: S(chars: "b", command: true), textEditing: false), "⌘ keys belong to the menus")
        // Hold K: J/L step frames instead of shuttling; release restores shuttle.
        XCTAssertEqual(r.action(for: S(chars: "l"), textEditing: false), .shuttle(.l))
        XCTAssertEqual(r.action(for: S(chars: "k"), textEditing: false), .shuttle(.k))
        XCTAssertNil(r.action(for: S(chars: "k"), textEditing: false, isRepeat: true))
        XCTAssertEqual(r.action(for: S(chars: "l"), textEditing: false), .stepFrames(1))
        XCTAssertEqual(r.action(for: S(chars: "j"), textEditing: false), .stepFrames(-1))
        r.releaseK()
        XCTAssertEqual(r.action(for: S(chars: "j"), textEditing: false), .shuttle(.j))
    }

    func testLaunchOptions() {
        let o = LaunchOptions.parse(["/p", "--scene", "NeverHeard", "--at", "12.4", "--fake-host",
                                     "--snapshot", "/tmp/s.png", "-NSDocumentRevisionsDebugMode", "YES"])
        XCTAssertEqual(o.projectPath?.path, "/p")
        XCTAssertEqual(o.scene, "NeverHeard")
        XCTAssertEqual(o.at, 12.4)
        XCTAssertTrue(o.fakeHost)
        XCTAssertEqual(o.snapshot, "/tmp/s.png")
        XCTAssertTrue(LaunchOptions.parse(["--fake-serve", "--fake-crash-at", "3"]).fakeServe)
        XCTAssertEqual(LaunchOptions.parse(["--fake-serve", "--fake-crash-at", "3"]).fakeCrashAt, 3)
    }
}
