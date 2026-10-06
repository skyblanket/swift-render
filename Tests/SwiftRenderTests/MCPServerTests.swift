import AppKit
import XCTest
@testable import SwiftRenderKit

/// swift-render-mcp against a fake project CLI (a shell script standing in for the
/// project's product): hung renders, cancellation, time limits, shutdown, and the
/// arguments that must never reach the file system unchecked.
final class MCPServerTests: XCTestCase {
    private var serverBin: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swift-render-mcp")
    }

    /// The fake CLI: logs its argv; `info Known` prints a SceneInfo; `frame … --at 99`
    /// hangs (recording its pid); other renders copy a fixture PNG to `--out`.
    private static let fakeCLI = """
    #!/bin/sh
    echo "$*" >> "$FAKE_LOG"
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
    case "$1" in
      info)
        if [ "$2" = Known ]; then cat "$FAKE_INFO"; exit 0; fi
        echo "Unknown scene: $2" >&2; exit 1 ;;
      frame)
        case " $* " in *" --at 99 "*) echo $$ > "$FAKE_PID"; exec sleep 600 ;; esac
        cp "$FAKE_PNG" "$out"; exit 0 ;;
      contact|check)
        cp "$FAKE_PNG" "$out"; exit 0 ;;
    esac
    exit 0

    """

    private struct Fake {
        var project: Project
        var log: URL
        var pidFile: URL
        var env: [String: String]
    }

    private func makeFake() throws -> Fake {
        guard FileManager.default.isExecutableFile(atPath: serverBin.path) else {
            throw XCTSkip("swift-render-mcp not built next to the test bundle (\(serverBin.path))")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-mcp-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Fake\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try #"{"product":"fakecli"}"#.write(to: root.appendingPathComponent("swift-render.json"), atomically: true, encoding: .utf8)
        let project = Project.open(root)
        // Where the server will look for the product (and find it up to date: written after the manifest).
        let bin = try ProjectBuilder.binPath(project)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = bin.appendingPathComponent("fakecli")
        try Self.fakeCLI.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let info = SceneInfo(name: "Known", kind: .render, duration: 4, width: 1920, height: 1080, fps: 60, knobs: [
            KnobInfo(key: "speed", kind: .double, defaultValue: .number(1), value: .number(1), min: 0, max: 4),
            KnobInfo(key: "accent", kind: .color, defaultValue: .string("#C7FF1A"), value: .string("#C7FF1A")),
        ])
        let infoURL = root.appendingPathComponent("info.json")
        try JSONEncoder().encode(info).write(to: infoURL)
        let png = root.appendingPathComponent("fixture.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let log = root.appendingPathComponent("cli.log"), pid = root.appendingPathComponent("hang.pid")
        return Fake(project: project, log: log, pidFile: pid, env: [
            "SWIFT_RENDER_ROOT": root.path, "FAKE_LOG": log.path, "FAKE_INFO": infoURL.path,
            "FAKE_PNG": png.path, "FAKE_PID": pid.path,
        ])
    }

    /// A line-oriented JSON-RPC client over the server's stdio.
    private final class Client: @unchecked Sendable {
        let process = Process()
        private let input = Pipe(), output = Pipe()
        private let lock = NSLock()
        private var buffer = Data()
        private var replies: [String: [String: Any]] = [:]

        init(_ bin: URL, env: [String: String]) throws {
            process.executableURL = bin
            process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.buffer.append(d)
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<nl]
                    self.buffer = Data(self.buffer[(nl + 1)...])
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = obj["id"] {
                        self.replies["\(id)"] = obj
                    }
                }
            }
            try process.run()
        }

        func send(_ obj: [String: Any]) {
            var data = try! JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }

        func call(_ id: Int, _ tool: String, _ args: [String: Any]) {
            send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": args]])
        }

        func reply(_ id: Int, within seconds: Double) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                lock.lock(); let r = replies["\(id)"]; lock.unlock()
                if let r { return r }
                usleep(20_000)
            } while Date() < deadline
            return nil
        }

        func closeInput() { try? input.fileHandleForWriting.close() }

        func stop() {
            if process.isRunning { process.terminate() }
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func start(_ fake: Fake, env extra: [String: String] = [:]) throws -> Client {
        let c = try Client(serverBin, env: fake.env.merging(extra) { $1 })
        addTeardownBlock { c.stop() }
        c.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]])
        XCTAssertNotNil(c.reply(1, within: 10), "initialize")
        return c
    }

    private func result(_ r: [String: Any]?) -> (isError: Bool, text: String) {
        let res = r?["result"] as? [String: Any] ?? [:]
        let text = ((res["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (res["isError"] as? Bool ?? true, text)
    }

    private func waitForHang(_ fake: Fake, previous: Int32? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> Int32 {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let s = try? String(contentsOf: fake.pidFile, encoding: .utf8),
               let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid != previous, kill(pid, 0) == 0 {
                return pid
            }
            usleep(50_000)
        }
        XCTFail("the hanging render never started", file: file, line: line)
        throw XCTSkip("no hang")
    }

    private func waitDead(_ pid: Int32, within seconds: Double = 6) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        return kill(pid, 0) != 0
    }

    // MARK: hung renders

    func testHungRenderNeverWedgesTheServer() throws {
        let fake = try makeFake()
        let c = try start(fake)
        c.call(2, "render_frames", ["scene": "Known", "times": [99]])
        let pid = try waitForHang(fake)

        c.send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        XCTAssertNotNil(c.reply(3, within: 3), "ping is answered while a render hangs")
        c.send(["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        XCTAssertNotNil(c.reply(4, within: 3), "tools/list too")

        c.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2, "reason": "user"]])
        XCTAssertTrue(waitDead(pid), "cancel stops the render's process group")
        c.call(5, "list_comments", [:])
        XCTAssertEqual(result(c.reply(5, within: 10)).isError, false, "the worker is free again")
        XCTAssertNil(c.reply(2, within: 0.5), "a cancelled request gets no response")

        // SIGTERM (the client stopping the server) takes the running child with it.
        c.call(6, "render_frames", ["scene": "Known", "times": [99]])
        let pid2 = try waitForHang(fake, previous: pid)
        c.process.terminate()
        c.process.waitUntilExit()
        XCTAssertTrue(waitDead(pid2), "no orphaned render after the server is stopped")
    }

    func testStuckRenderTimesOutWithAnError() throws {
        let fake = try makeFake()
        let c = try start(fake, env: ["SWIFT_RENDER_MCP_TIMEOUT": "1"])
        c.call(2, "render_frames", ["scene": "Known", "times": [99]])
        let pid = try waitForHang(fake)
        let r = result(c.reply(2, within: 30))
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("timed out"), r.text)
        XCTAssertTrue(r.text.contains("t=99"), r.text)
        XCTAssertTrue(waitDead(pid))
    }

    func testClosedStdinStopsAStuckCall() throws {
        let fake = try makeFake()
        let c = try start(fake, env: ["SWIFT_RENDER_MCP_EOF_GRACE": "1"])
        c.call(2, "render_frames", ["scene": "Known", "times": [99]])
        let pid = try waitForHang(fake)
        c.closeInput()
        let deadline = Date().addingTimeInterval(10)
        while c.process.isRunning, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(c.process.isRunning, "the server exits after stdin closes")
        XCTAssertTrue(waitDead(pid))
    }

    // MARK: plugin launcher

    /// The plugin's launcher runs at every session start in any directory: it must not
    /// build (or fetch for, or run) a package there unless that directory is trusted.
    func testPluginLauncherNeverBuildsAnUntrustedPackage() throws {
        let launcher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("claude-plugin/bin/swift-render-mcp-launch")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-hostile-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Evil", products: [.executable(name: "swift-render-mcp", targets: ["Evil"])],
                              targets: [.executableTarget(name: "Evil")])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        func run(_ env: [String: String]) throws -> (status: Int32, out: String, err: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [launcher.path]
            p.currentDirectoryURL = dir
            p.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(env) { $1 }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }

        let studioInstalled = FileManager.default.fileExists(atPath: "/Applications/swift-render Studio.app")
        let r = try run([:])
        if !studioInstalled {
            XCTAssertEqual(r.status, 1, r.err)
            XCTAssertTrue(r.err.contains("trusted-projects"), r.err)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".build").path),
                       "nothing was built in an untrusted directory")

        // An explicit binary wins, and an init'd app root points the server at Launch/.
        let launch = dir.appendingPathComponent("Launch")
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try "{}".write(to: launch.appendingPathComponent("swift-render.json"), atomically: true, encoding: .utf8)
        let e = try run(["SWIFT_RENDER_MCP": "/usr/bin/env"])
        XCTAssertEqual(e.status, 0)
        XCTAssertNotNil(e.out.range(of: "SWIFT_RENDER_ROOT=[^\\n]*/\(dir.lastPathComponent)/Launch\\n", options: .regularExpression), e.out)
    }

    // MARK: arguments that reach the file system

    func testSetKnobsOnlyWritesKnownScenesKnobFiles() throws {
        let fake = try makeFake()
        let root = fake.project.root
        let mcp = root.appendingPathComponent(".mcp.json")
        try #"{"mcpServers":{"keep":{"command":"x"}}}"#.write(to: mcp, atomically: true, encoding: .utf8)
        let c = try start(fake)

        c.call(2, "set_knobs", ["scene": "../../.mcp", "values": ["mcpServers": "pwned"]])
        c.call(3, "set_knobs", ["scene": "../../swift-render", "values": [:], "reset": true])
        for id in [2, 3] {
            let r = result(c.reply(id, within: 20))
            XCTAssertTrue(r.isError, r.text)
            XCTAssertTrue(r.text.contains("not a scene name"), r.text)
        }
        XCTAssertEqual(try String(contentsOf: mcp, encoding: .utf8), #"{"mcpServers":{"keep":{"command":"x"}}}"#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("swift-render.json").path))

        c.call(4, "set_knobs", ["scene": "Nope", "values": ["a": 1]])
        let unknown = result(c.reply(4, within: 20))
        XCTAssertTrue(unknown.isError && unknown.text.contains("unknown scene"), unknown.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.project.knobsURL(scene: "Nope").path), "no orphan file")

        c.call(5, "set_knobs", ["scene": "Known", "values": ["a": 1]])
        XCTAssertEqual(result(c.reply(5, within: 20)).isError, false)
        XCTAssertEqual(KnobFile.load(fake.project.knobsURL(scene: "Known")), ["a": .number(1)])

        let conflicted = "<<<<<<< HEAD\n{\"a\": 1}\n=======\n{\"a\": 3}\n>>>>>>> theirs\n"
        try conflicted.write(to: fake.project.knobsURL(scene: "Known"), atomically: true, encoding: .utf8)
        c.call(6, "set_knobs", ["scene": "Known", "values": ["a": 2]])
        XCTAssertTrue(result(c.reply(6, within: 20)).isError)
        XCTAssertEqual(try String(contentsOf: fake.project.knobsURL(scene: "Known"), encoding: .utf8), conflicted)

        // A value the engine would ignore (wrong type for the declared knob) is refused, not saved.
        try FileManager.default.removeItem(at: fake.project.knobsURL(scene: "Known"))
        c.call(8, "set_knobs", ["scene": "Known", "values": ["speed": "fast", "accent": "lime"]])
        let mistyped = result(c.reply(8, within: 20))
        XCTAssertTrue(mistyped.isError, mistyped.text)
        XCTAssertTrue(mistyped.text.contains("speed: expected a number") && mistyped.text.contains("accent:"), mistyped.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.project.knobsURL(scene: "Known").path))
        c.call(9, "set_knobs", ["scene": "Known", "values": ["speed": 2.5, "accent": "#FF8800"]])
        XCTAssertEqual(result(c.reply(9, within: 20)).isError, false)
        XCTAssertEqual(KnobFile.load(fake.project.knobsURL(scene: "Known")), ["speed": .number(2.5), "accent": .string("#FF8800")])

        c.call(7, "render_frames", ["scene": "a/../../../../victim/photo", "times": [1]])
        XCTAssertTrue(result(c.reply(7, within: 20)).text.contains("not a scene name"))
    }

    func testNonFiniteTimesAreRefusedAndTheServerSurvives() throws {
        let fake = try makeFake()
        let c = try start(fake)
        let bad: [Any] = [["nan"], ["inf"], "1e400", [1e19], [-1]]
        for (i, times) in bad.enumerated() {
            c.call(10 + i, "render_frames", ["scene": "Known", "times": times])
            let r = result(c.reply(10 + i, within: 20))
            XCTAssertTrue(r.isError, "\(times): \(r.text)")
            XCTAssertTrue(r.text.contains("finite"), r.text)
        }
        c.send(["jsonrpc": "2.0", "id": 99, "method": "ping"])
        XCTAssertNotNil(c.reply(99, within: 5), "still alive")
        c.call(100, "render_frames", ["scene": "Known", "times": "1.5"])
        XCTAssertEqual(result(c.reply(100, within: 20)).isError, false)
    }

    func testFrameToolsRenderOnTheCommentsCanvas() throws {
        let fake = try makeFake()
        let store = ReviewStore(project: fake.project)
        var note = ReviewComment(t: 1, region: ReviewRegion(x: 0.1, y: 0.3, w: 0.5, h: 0.2), body: "title",
                                 author: ReviewAuthor(name: "Sky"), context: ["aspect": "9:16"])
        note.canvas = ReviewCanvas(width: 1080, height: 1920, fps: 60)
        try store.add(scene: "Known", note)
        var crafted = ReviewComment(id: "../../../escaped", t: 1, body: "x", author: ReviewAuthor(name: "Mallory"))
        crafted.canvas = nil
        try store.add(scene: "Known", crafted)

        let c = try start(fake)
        c.call(2, "render_frames", ["scene": "Known", "times": [1], "comment": note.id])
        XCTAssertEqual(result(c.reply(2, within: 30)).isError, false)
        c.call(3, "contact_sheet", ["scene": "Known", "comment": note.id])
        XCTAssertEqual(result(c.reply(3, within: 30)).isError, false)
        c.call(4, "check_scene", ["scene": "Known", "aspect": "9:16"])
        XCTAssertEqual(result(c.reply(4, within: 30)).isError, false)
        c.call(5, "claim_comment", ["id": "../../../escaped"])
        XCTAssertNotNil(c.reply(5, within: 30))

        let calls = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        let frame = try XCTUnwrap(calls.first { $0.hasPrefix("frame Known --at 1 ") })
        XCTAssertTrue(frame.contains("--width 1080 --height 1920 --fps 60"), frame)
        XCTAssertTrue(try XCTUnwrap(calls.first { $0.hasPrefix("contact Known") }).contains("--width 1080 --height 1920"))
        XCTAssertTrue(try XCTUnwrap(calls.first { $0.hasPrefix("check Known") }).contains("--aspect 9:16"))
        // The crafted id's before-frame lands inside attachments/, nowhere else.
        let claimOut = try XCTUnwrap(calls.last { $0.hasPrefix("frame Known") }?.components(separatedBy: "--out ").last?
            .components(separatedBy: " ").first)
        XCTAssertEqual(URL(fileURLWithPath: claimOut).deletingLastPathComponent().standardizedFileURL.path,
                       fake.project.attachmentsDir.standardizedFileURL.path, claimOut)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fake.project.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("escaped-before.png").path))
    }
}
