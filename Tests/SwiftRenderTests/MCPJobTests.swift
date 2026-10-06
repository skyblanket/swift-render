import AppKit
import XCTest
@testable import SwiftRenderKit

/// swift-render-mcp's jobs: renders, launch films and builds that outlive a tool call some
/// clients stop after ~60 s (Claude Desktop). The call answers with a job id after
/// SWIFT_RENDER_MCP_DETACH_AFTER seconds, the work goes on, and render_status reports
/// progress and the result. Plus write_scene, for clients without file tools. The
/// `swift-render` CLI is a shell script (SWIFT_RENDER_CLI) whose renders take a while.
final class MCPJobTests: XCTestCase {
    private var serverBin: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swift-render-mcp")
    }

    /// `render` prints `--progress json` lines for FAKE_STEPS × 0.1 s; `launch` redraws a
    /// percent on stderr; both record their pid. `init` scaffolds a Launch/ like the real one.
    private static let fakeCLI = """
    #!/bin/sh
    echo "$*" >> "$FAKE_LOG"
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
    steps=${FAKE_STEPS:-20}
    case "$1" in
      list)
        cat "$FAKE_LIST"; exit 0 ;;
      props)
        echo "$2 takes no props" >&2; exit 1 ;;
      render)
        echo $$ > "$FAKE_PID"
        i=0
        while [ $i -lt $steps ]; do
          i=$((i+1)); echo "{\\"progress\\":{\\"frame\\":$((i*10)),\\"total\\":$((steps*10)),\\"fps\\":40}}" >&2; sleep 0.1
        done
        : > "$out"; echo "[swift-render] done in 2.0s → $out"; exit 0 ;;
      launch)
        root="$2"; dir="$root/.swift-render/launch"; mkdir -p "$dir"
        [ -f "$dir/Slow.json" ] || echo '{"name": "Slow App", "tagline": "t", "features": []}' > "$dir/Slow.json"
        echo "[swift-render] launch: scanned $root (0.1s)"
        echo "  name        Slow App   ← Package.swift"
        echo "  props       .swift-render/launch/Slow.json"
        case " $* " in *" --no-render "*) exit 0 ;; esac
        echo $$ > "$FAKE_PID"
        echo "[swift-render] rendering AppleLaunch · 31.2s"
        for p in 0 10 20 30 40 50 60 70 80 90; do printf "\\r[swift-render] %s%%" $p >&2; sleep 0.15; done
        mkdir -p "$root/out"; : > "$root/out/slow-app-launch.mp4"
        echo "[swift-render] film → $root/out/slow-app-launch.mp4  (1.5s)"
        exit 0 ;;
      init)
        l="$2/Launch"; mkdir -p "$l/Sources/LaunchScenes"
        echo '{"product": "launch", "scenesDir": "Sources/LaunchScenes"}' > "$l/swift-render.json"
        echo "[swift-render] init: $l"; exit 0 ;;
      contact|frame|check)
        cp "$FAKE_PNG" "$out"; exit 0 ;;
    esac
    exit 0

    """

    private struct Fake {
        var root: URL
        var log: URL
        var pid: URL
        var env: [String: String]
    }

    private func makeFake() throws -> Fake {
        guard FileManager.default.isExecutableFile(atPath: serverBin.path) else {
            throw XCTSkip("swift-render-mcp not built next to the test bundle (\(serverBin.path))")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let real = try XCTUnwrap(realpath(tmp.path, nil))
        let base = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Pebble")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10\nimport PackageDescription\nlet package = Package(name: \"Pebble\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let cli = base.appendingPathComponent("bin/swift-render")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.fakeCLI.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let list = base.appendingPathComponent("list.json")
        try JSONEncoder().encode([SceneSummary(name: "Slow", kind: .render, defaultDuration: 3, hasSoundtrack: false,
                                               hasProps: false)]).write(to: list)
        let png = base.appendingPathComponent("fixture.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let log = base.appendingPathComponent("cli.log"), pid = base.appendingPathComponent("job.pid")
        return Fake(root: root, log: log, pid: pid, env: [
            "SWIFT_RENDER_ROOT": "", "SWIFT_RENDER_CLI": cli.path, "FAKE_LOG": log.path, "FAKE_LIST": list.path,
            "FAKE_PNG": png.path, "FAKE_PID": pid.path,
        ])
    }

    private func start(_ fake: Fake, env extra: [String: String] = [:]) throws -> MCPTestClient {
        let c = try MCPTestClient(serverBin, env: fake.env.merging(extra) { $1 }, cwd: fake.root)
        addTeardownBlock { c.stop() }
        XCTAssertNotNil(c.initialize())
        return c
    }

    private func waitForPid(_ fake: Fake, previous: Int32? = nil) throws -> Int32 {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let s = try? String(contentsOf: fake.pid, encoding: .utf8),
               let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid != previous, kill(pid, 0) == 0 {
                return pid
            }
            usleep(30_000)
        }
        XCTFail("the render never started")
        throw XCTSkip("no render")
    }

    private func waitDead(_ pid: Int32, within seconds: Double = 6) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        return kill(pid, 0) != 0
    }

    /// render_status until the job is no longer running (each call waits at most the detach time).
    private func finish(_ c: MCPTestClient, _ job: String) -> (isError: Bool, text: String, images: Int) {
        let deadline = Date().addingTimeInterval(30)
        var r = c.tool("render_status", ["job": job, "wait": 20], within: 30)
        while r.text.contains(" · running") || r.text.contains(" · queued"), Date() < deadline {
            r = c.tool("render_status", ["job": job, "wait": 20], within: 30)
        }
        return r
    }

    // MARK: detach + render_status

    func testLongRenderAnswersWithAJobAndRenderStatusReturnsTheResult() throws {
        let fake = try makeFake()
        let c = try start(fake, env: ["SWIFT_RENDER_MCP_DETACH_AFTER": "1", "FAKE_STEPS": "30"])
        let out = fake.root.appendingPathComponent("out/Slow.mp4").path

        let t0 = Date()
        let r = c.tool("render_video", ["scene": "Slow"], within: 10)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.8, "answered at the detach point, not at the end (3 s)")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("as job j1") && r.text.contains("render_status {job:\"j1\"}") && r.text.contains(out), r.text)

        // The worker is free while the job renders.
        let t1 = Date()
        XCTAssertFalse(c.tool("list_scenes").isError)
        XCTAssertLessThan(Date().timeIntervalSince(t1), 2)
        let running = c.tool("render_status", ["job": "j1", "wait": 0])
        XCTAssertFalse(running.isError, running.text)
        XCTAssertTrue(running.text.contains("running") && running.text.contains("frames"), running.text)

        let done = finish(c, "j1")
        XCTAssertFalse(done.isError, done.text)
        XCTAssertTrue(done.text.contains("j1 render_video Slow · done") && done.text.contains("rendered Slow"), done.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        XCTAssertTrue(c.tool("render_status").text.contains("j1 render_video Slow · done"))
        XCTAssertTrue(c.tool("render_status", ["job": "j99"]).isError)
        XCTAssertTrue(c.tool("render_status", ["job": "j1"]).text.contains("rendered Slow"), "a finished job keeps its result")
    }

    func testWaitFlagsAndProgressNotifications() throws {
        let fake = try makeFake()
        let c = try start(fake, env: ["SWIFT_RENDER_MCP_DETACH_AFTER": "1", "FAKE_STEPS": "20"])

        // wait: true blocks past the detach point (clients without a time cap).
        let blocked = c.tool("render_video", ["scene": "Slow", "wait": true], within: 20)
        XCTAssertTrue(blocked.text.contains("rendered Slow"), blocked.text)

        // A progressToken gets notifications/progress while the call waits — increasing, with the frame total.
        let reply = c.request("tools/call", ["name": "render_video", "arguments": ["scene": "Slow", "wait": true],
                                             "_meta": ["progressToken": "tok-1"]], within: 20)
        XCTAssertNotNil(reply)
        let progress = c.notifications.filter { $0["method"] as? String == "notifications/progress" }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertFalse(progress.isEmpty, "progress was reported")
        XCTAssertTrue(progress.allSatisfy { $0["progressToken"] as? String == "tok-1" })
        let values = progress.compactMap { $0["progress"] as? Double }
        XCTAssertEqual(values, values.sorted(), "progress only increases")
        XCTAssertTrue(progress.contains { $0["total"] as? Double == 200 }, "\(progress)")

        // wait: false answers at once.
        let t0 = Date()
        let now = c.tool("render_video", ["scene": "Slow", "wait": false])
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertTrue(now.text.contains("started as job j3"), now.text)
        XCTAssertTrue(finish(c, "j3").text.contains("rendered Slow"))
    }

    func testJobsStopOnCancelAndShutdown() throws {
        let fake = try makeFake()
        let c = try start(fake, env: ["SWIFT_RENDER_MCP_DETACH_AFTER": "30", "FAKE_STEPS": "600"])

        // render_status {cancel} stops a detached job's process group.
        XCTAssertTrue(c.tool("render_video", ["scene": "Slow", "wait": false]).text.contains("job j1"))
        let pid = try waitForPid(fake)
        let stopped = c.tool("render_status", ["job": "j1", "cancel": true])
        XCTAssertTrue(stopped.text.contains("cancelled"), stopped.text)
        XCTAssertTrue(waitDead(pid))

        // notifications/cancelled before the call detached stops the job too, and gets no reply.
        c.call(50, "render_video", ["scene": "Slow"])
        let pid2 = try waitForPid(fake, previous: pid)
        c.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 50]])
        XCTAssertTrue(waitDead(pid2), "cancel stops the render")
        XCTAssertNil(c.reply(50, within: 1), "a cancelled request gets no response")
        XCTAssertTrue(c.tool("render_status", ["job": "j2"]).text.contains("cancelled"))

        // A detached job dies with the server — no orphaned renders.
        XCTAssertTrue(c.tool("render_video", ["scene": "Slow", "wait": false]).text.contains("job j3"))
        let pid3 = try waitForPid(fake, previous: pid2)
        c.process.terminate()
        c.process.waitUntilExit()
        XCTAssertTrue(waitDead(pid3), "the server's shutdown stops its jobs")
    }

    func testLaunchFilmDetachesWithThePlannedFilmAndFinishesWithTheSheet() throws {
        let fake = try makeFake()
        let kept = fake.root.appendingPathComponent(".swift-render/launch/Slow.json")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"name": "Slow App", "tagline": "kept", "features": []}"#.write(to: kept, atomically: true, encoding: .utf8)
        let c = try start(fake, env: ["SWIFT_RENDER_MCP_DETACH_AFTER": "0.5"])

        let r = c.tool("launch_film", ["preview": true], within: 10)
        XCTAssertFalse(r.isError, r.text)
        let film = fake.root.appendingPathComponent("out/slow-app-launch.mp4").path
        XCTAssertTrue(r.text.contains("launch_film Pebble (16:9, preview)") && r.text.contains("job j1"), r.text)
        XCTAssertTrue(r.text.contains(film), "the planned film path, before it exists: \(r.text)")
        XCTAssertEqual(r.images, 0)
        usleep(800_000)
        XCTAssertTrue(c.tool("render_status", ["job": "j1", "wait": 0]).text.contains("rendering"))

        let done = finish(c, "j1")
        XCTAssertFalse(done.isError, done.text)
        XCTAssertTrue(done.text.contains("film: \(film)") && done.text.contains("props file: \(kept.path)"), done.text)
        XCTAssertEqual(done.images, 1, "the contact sheet comes with the result")
    }

    // MARK: write_scene

    func testWriteSceneIsConfinedAndReportsTheBuild() throws {
        let fake = try makeFake()
        let c = try start(fake)
        let source = "import SwiftUI\nimport SwiftRender\n\npublic struct Teaser: RenderScene {\n}\n"
        XCTAssertTrue(c.tool("write_scene", ["name": "Teaser", "source": source]).text.contains("init_project"))
        XCTAssertFalse(c.tool("init_project").isError)
        let scenes = fake.root.appendingPathComponent("Launch/Sources/LaunchScenes")

        for (name, src, why) in [("Teaser", "struct Teaser {}", "must declare"),
                                 ("Teaser", "public struct Other: RenderScene {}", "must declare"),
                                 ("../Evil", source, "UpperCamelCase"),
                                 ("Text", source, "already a type")] {
            let r = c.tool("write_scene", ["name": name, "source": src])
            XCTAssertTrue(r.isError && r.text.contains(why), "\(name): \(r.text)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenes.appendingPathComponent("Teaser.swift").path))

        // Written, then built: the build's verdict is the answer (no Package.swift here → it fails fast).
        let r = c.tool("write_scene", ["name": "Teaser", "source": source], within: 120)
        XCTAssertTrue(r.text.contains("created Sources/LaunchScenes/Teaser.swift"), r.text)
        XCTAssertTrue(r.isError && r.text.contains("BUILD FAILED"), r.text)
        XCTAssertEqual(try String(contentsOf: scenes.appendingPathComponent("Teaser.swift"), encoding: .utf8), source)
        XCTAssertTrue(c.tool("write_scene", ["name": "Teaser", "source": source], within: 120).text.contains("replaced"))

        // Another file already declaring the type: refused before writing.
        try "public struct Dupe: RenderScene {}\n".write(to: scenes.appendingPathComponent("Other.swift"), atomically: true, encoding: .utf8)
        let dupe = c.tool("write_scene", ["name": "Dupe", "source": source.replacingOccurrences(of: "Teaser", with: "Dupe")])
        XCTAssertTrue(dupe.isError && dupe.text.contains("already declares Dupe"), dupe.text)

        // A symlinked scenes folder can't carry the write out of the project.
        let outside = fake.root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: scenes)
        try FileManager.default.createSymbolicLink(at: scenes, withDestinationURL: outside)
        let escaped = c.tool("write_scene", ["name": "Teaser", "source": source])
        XCTAssertTrue(escaped.isError && escaped.text.contains("symlink"), escaped.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}
