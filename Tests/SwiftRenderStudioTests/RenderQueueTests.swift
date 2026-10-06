import XCTest
import SwiftRenderKit
@testable import SwiftRenderStudio

/// Presets, validation and the queue end to end against a fake project CLI: a shell
/// script that speaks `render … --progress json` (progress lines on stderr, the output
/// file written at the end, its own argv recorded inside the file).
@MainActor
final class RenderQueueTests: XCTestCase {
    var root: URL!
    var cli: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rq-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cli = root.appendingPathComponent("fake-cli.sh")
        try """
        #!/bin/sh
        # fake swift-render: render <Scene> … --out <path> … --progress json
        out=""; prev=""
        for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
        echo "[swift-render] scene=$2 duration=1.0s range=0.0-1.0s fps=30 size=960×540 frames=30 → $out"
        mkdir -p "$(dirname "$out")"
        if [ -n "$FAKE_PARTIAL" ]; then echo partial > "$out"; fi
        if [ -n "$FAKE_STAGES" ]; then
          printf '{"stage":"audio","detail":"Synthesizing the score"}\\n' >&2
          sleep ${FAKE_STEP:-0.05}
          printf '{"stage":"render"}\\n' >&2
        fi
        for i in 10 20 30; do
          printf '{"progress":{"frame":%d,"total":30,"fps":120.0}}\\n' $i >&2
          sleep ${FAKE_STEP:-0.05}
        done
        [ -n "$FAKE_STAGES" ] && printf '{"stage":"mux","detail":"Finishing the file"}\\n' >&2 && sleep ${FAKE_STEP:-0.05}
        echo "args: $*" > "$out"
        echo "[swift-render] done in 0.2s → $out"
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    override func tearDown() async throws {
        unsetenv("FAKE_STEP"); unsetenv("FAKE_PARTIAL"); unsetenv("FAKE_STAGES")
        try? FileManager.default.removeItem(at: root)
    }

    private func queue() -> RenderQueue {
        let exe = cli!
        let q = RenderQueue(project: Project(root: root), resolveExecutable: { _, _, progress in
            progress("[1/1] Compiling (fake)")
            return exe
        }, ffmpeg: .some(nil))
        q.inputs = { _ in RenderInputs(knobs: ["accent": .number(0.5)], hasSoundtrack: false, duration: 1) }
        return q
    }

    private func wait(_ q: RenderQueue, _ id: RenderJob.ID, timeout: Double = 15,
                      until done: (RenderJob) -> Bool) async -> RenderJob? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let j = q.job(id), done(j) { return j }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return q.job(id)
    }

    // MARK: Presets

    func testPresetArgs() {
        let out = URL(fileURLWithPath: "/p/out/x.mp4")
        XCTAssertEqual(RenderPreset.master1080p60.args(scene: "S", out: out), ["render", "S", "--out", "/p/out/x.mp4", "--fps", "60"])
        let uhd = RenderPreset.uhd4k.args(scene: "S", out: out)
        XCTAssertTrue(uhd.joined(separator: " ").contains("--scale 2"), "4K = Recorder size × scale 2")
        XCTAssertEqual(RenderPreset.uhd4k.pixelSize.width, 3840)
        let portrait = RenderPreset.appStorePortrait.args(scene: "S", out: out).joined(separator: " ")
        XCTAssertTrue(portrait.contains("--fps 30 --width 886 --height 1920"))
        let landscape = RenderPreset.appStoreLandscape.args(scene: "S", out: out).joined(separator: " ")
        XCTAssertTrue(landscape.contains("--width 1920 --height 886"))
        XCTAssertTrue(RenderPreset.square.args(scene: "S", out: out).contains("1:1"))
        XCTAssertTrue(RenderPreset.gif.args(scene: "S", out: out).contains("--no-postfx"))
        XCTAssertEqual(RenderPreset.gif.fileExtension, "gif")
        XCTAssertTrue(RenderPreset.vertical9x16.changesAspect)
        XCTAssertFalse(RenderPreset.uhd4k.changesAspect)
        XCTAssertEqual(RenderPreset.master1080p60.sizeLabel, "1920×1080")
    }

    func testAppStoreDurationLimit() {
        let p = RenderPreset.appStorePortrait
        XCTAssertNotNil(p.durationProblem(9.9))
        XCTAssertNotNil(p.durationProblem(14.9))
        XCTAssertNil(p.durationProblem(15))
        XCTAssertNil(p.durationProblem(25.2))
        XCTAssertNil(p.durationProblem(30.0))
        XCTAssertNotNil(p.durationProblem(30.05))
        XCTAssertNil(RenderPreset.master1080p60.durationProblem(600))
        // A range overrides the scene length.
        XCTAssertNil(RenderQueue.problem(preset: p, duration: 93, range: 10...30, ffmpegAvailable: true))
        XCTAssertNotNil(RenderQueue.problem(preset: p, duration: 93, range: nil, ffmpegAvailable: true))
        XCTAssertNotNil(RenderQueue.problem(preset: .gif, duration: 5, range: nil, ffmpegAvailable: false))
    }

    func testEnqueueRejectsInvalidAppPreview() {
        let q = queue()
        let id = q.enqueue(scene: "Long", preset: .appStoreLandscape, range: nil, build: .optimized, knobs: .useLive)
        guard case .failed(let why) = q.job(id)?.state else { return XCTFail("expected failure, got \(String(describing: q.job(id)?.state))") }
        XCTAssertTrue(why.contains("15–30"))
    }

    func testDefaultOutputIsUnique() throws {
        let project = Project(root: root)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = RenderQueue.defaultOutput(project: project, scene: "S", preset: .preview, date: date)
        let b = RenderQueue.defaultOutput(project: project, scene: "S", preset: .preview, date: date, taken: [a.path])
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.lastPathComponent.hasSuffix("-2.mp4"))
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "out")
    }

    func testParseFrames() {
        XCTAssertEqual(RenderQueue.parseFrames("[swift-render] scene=X fps=60 frames=540 → out/x.mp4"), 540)
        XCTAssertNil(RenderQueue.parseFrames("[swift-render] audio: none"))
    }

    // MARK: Running

    func testRenderRunsWithProgressKnobsAndFinishes() async throws {
        setenv("FAKE_STEP", "0.15", 1)
        let q = queue()
        let id = q.enqueue(scene: "Demo", preset: .preview, range: 0.5...1.0, build: .optimized, knobs: .useLive)
        let mid = await wait(q, id) { if case .rendering(let d, _, _) = $0.state { return d > 0 }; return $0.isDone }
        guard case .rendering(let done, let total, let fps) = mid?.state else { return XCTFail("no progress: \(String(describing: mid?.state))") }
        XCTAssertEqual(total, 30)
        XCTAssertGreaterThan(done, 0)
        XCTAssertEqual(fps, 120)
        XCTAssertNotNil(mid?.eta)

        let job = await wait(q, id) { $0.isDone }
        guard case .finished = job?.state else { return XCTFail("not finished: \(String(describing: job?.state)) \(job?.log ?? [])") }
        let out = try XCTUnwrap(job?.output)
        let args = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(args.contains("render Demo --out"))
        XCTAssertTrue(args.contains("--preview"))
        XCTAssertTrue(args.contains("--range 0.5000:1.0000"))
        XCTAssertTrue(args.contains("--knobs "), "live knobs are snapshotted into a file")
        XCTAssertTrue(args.contains("--progress json"))
        XCTAssertNotNil(job?.bytes)
        // Scratch inputs are cleaned up.
        let scratch = Project(root: root).cacheDir.appendingPathComponent("renders")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [], [])
        XCTAssertEqual(q.recentOutputs().map(\.lastPathComponent), [out.lastPathComponent])
    }

    /// `{"stage":…}` lines name the steps around the frames: the job never sits on a
    /// vague "Starting…", and a whole-film export renders with `--jobs auto`.
    func testStageLinesDriveTheStatus() async throws {
        setenv("FAKE_STEP", "0.4", 1)
        setenv("FAKE_STAGES", "1", 1)
        let q = queue()
        let id = q.enqueue(scene: "Demo", preset: .master1080p60, range: nil, build: .optimized, knobs: .saveToFile)
        let music = await wait(q, id) { if case .preparing(let s) = $0.state { return s.contains("music") }; return $0.isDone }
        XCTAssertEqual(music?.state, .preparing("Preparing music…"))
        XCTAssertEqual(music?.statusLine, "Preparing music…")
        let rendering = await wait(q, id) { $0.state.isRendering || $0.isDone }
        XCTAssertTrue(rendering?.statusLine.hasPrefix("Rendering ") ?? false, rendering?.statusLine ?? "")
        let finishing = await wait(q, id) { if case .finishing = $0.state { return true }; return $0.isDone }
        XCTAssertEqual(finishing?.state, .finishing("Finishing up…"))
        let job = await wait(q, id) { $0.isDone }
        guard case .finished = job?.state else { return XCTFail("not finished: \(String(describing: job?.state))") }
        let args = try String(contentsOf: try XCTUnwrap(job?.output), encoding: .utf8)
        XCTAssertTrue(args.contains("--jobs auto"), args)
    }

    func testStatusLineWording() {
        var j = RenderJob(id: UUID(), scene: "S", preset: .master1080p60, range: nil, build: .optimized,
                          knobs: .saveToFile, output: URL(fileURLWithPath: "/tmp/x.mp4"))
        j.state = .rendering(done: 120, total: 900, fps: 42)
        XCTAssertEqual(j.statusLine, "Rendering 120 of 900 · 42 fps · about 19 s left")
        j.state = .rendering(done: 10, total: 900, fps: 0)
        XCTAssertEqual(j.statusLine, "Rendering 10 of 900")
        j.state = .building("[3/9] Compiling")
        XCTAssertEqual(j.statusLine, "Building for export…")
        XCTAssertEqual(RenderQueue.state(after: RenderStageLine(.mux), current: .rendering(done: 9, total: 9, fps: 1)),
                       .finishing("Finishing up…"))
        // A late audio line never pulls a rendering job back to "preparing".
        XCTAssertEqual(RenderQueue.state(after: RenderStageLine(.audio), current: .rendering(done: 1, total: 9, fps: 1)),
                       .rendering(done: 1, total: 9, fps: 1))
        XCTAssertTrue(RenderPreset.allCases.allSatisfy(\.prefersRelease), "every export defaults to the release CLI")
    }

    /// The release CLI is reused until a source is newer than it.
    func testReleaseExecutableFreshness() throws {
        let fm = FileManager.default
        let src = root.appendingPathComponent("Sources/App", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("Scene.swift")
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
        try "// manifest".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = Project(root: root)
        let exe = RenderQueue.scratchPath(project, configuration: "release").appendingPathComponent("release/swift-render")
        XCTAssertTrue(exe.path.contains(".build/studio-release/release/"))
        XCTAssertFalse(RenderQueue.isFresh(exe, project: project), "not built yet")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "bin".write(to: exe, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-60)
        for u in [file, src, src.deletingLastPathComponent(), root.appendingPathComponent("Package.swift")] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path)
        }
        XCTAssertTrue(RenderQueue.isFresh(exe, project: project))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertFalse(RenderQueue.isFresh(exe, project: project), "an edited source needs a rebuild")
    }

    func testJobsRunOneAtATime() async {
        let q = queue()
        let a = q.enqueue(scene: "A", preset: .preview, range: nil, build: .optimized, knobs: .saveToFile)
        let b = q.enqueue(scene: "B", preset: .preview, range: nil, build: .optimized, knobs: .saveToFile)
        XCTAssertEqual(q.job(b)?.state, .queued)
        _ = await wait(q, b) { $0.isDone }
        XCTAssertEqual(q.job(a)?.state.isFinished, true)
        XCTAssertEqual(q.job(b)?.state.isFinished, true)
        XCTAssertLessThanOrEqual(q.job(a)!.startedAt!, q.job(b)!.startedAt!)
        q.clearDone()
        XCTAssertTrue(q.jobs.isEmpty)
    }

    func testCancelStopsTheRenderAndDeletesPartialOutput() async throws {
        setenv("FAKE_STEP", "10", 1)
        setenv("FAKE_PARTIAL", "1", 1)
        let q = queue()
        let id = q.enqueue(scene: "Demo", preset: .master1080p60, range: nil, build: .optimized, knobs: .useLive)
        let started = await wait(q, id) { if case .rendering(let d, _, _) = $0.state { return d > 0 }; return $0.isDone }
        let out = try XCTUnwrap(started?.output)
        let partial = RenderQueue.partialURL(for: out, tag: String(id.uuidString.prefix(8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "fake CLI wrote a partial file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the destination is only written on success")
        let t0 = Date()
        q.cancel(id)
        let job = await wait(q, id, timeout: 8) { $0.isDone }
        XCTAssertEqual(job?.state, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "SIGINT ends the fake CLI right away")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: An existing file chosen as the output (Change… → Replace)

    private func existingMaster() throws -> URL {
        let url = root.appendingPathComponent("out/Delivered-master.mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "the delivered master".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFailedBuildKeepsTheFileItWasToReplace() async throws {
        let master = try existingMaster()
        let q = RenderQueue(project: Project(root: root), resolveExecutable: { _, _, _ in
            throw RenderQueueError.build("release build failed — Scene.swift:3: error: boom")
        }, ffmpeg: .some(nil))
        let id = q.enqueue(scene: "A", preset: .master1080p60, range: nil, build: .optimized, knobs: .saveToFile, output: master)
        let job = await wait(q, id) { $0.isDone }
        guard case .failed = job?.state else { return XCTFail("\(String(describing: job?.state))") }
        XCTAssertEqual(try String(contentsOf: master, encoding: .utf8), "the delivered master")
    }

    func testCancelDuringBuildKeepsTheFileItWasToReplace() async throws {
        let master = try existingMaster()
        let q = RenderQueue(project: Project(root: root), resolveExecutable: { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw RenderQueueError.build("unreachable")
        }, ffmpeg: .some(nil))
        let id = q.enqueue(scene: "A", preset: .master1080p60, range: nil, build: .optimized, knobs: .saveToFile, output: master)
        _ = await wait(q, id) { if case .building = $0.state { return true }; return $0.isDone }
        q.cancel(id)
        let job = await wait(q, id) { $0.isDone }
        XCTAssertEqual(job?.state, .cancelled)
        XCTAssertEqual(try String(contentsOf: master, encoding: .utf8), "the delivered master")
    }

    func testFailedRenderKeepsTheFileAndSuccessReplacesIt() async throws {
        let master = try existingMaster()
        let failing = RenderQueue(project: Project(root: root), resolveExecutable: { _, _, _ in URL(fileURLWithPath: "/usr/bin/false") },
                                  ffmpeg: .some(nil))
        let bad = failing.enqueue(scene: "A", preset: .master1080p60, range: nil, build: .optimized, knobs: .saveToFile, output: master)
        let failed = await wait(failing, bad) { $0.isDone }
        guard case .failed = failed?.state else { return XCTFail("\(String(describing: failed?.state))") }
        XCTAssertEqual(try String(contentsOf: master, encoding: .utf8), "the delivered master")

        let q = queue()
        let good = q.enqueue(scene: "Demo", preset: .master1080p60, range: nil, build: .optimized, knobs: .saveToFile, output: master)
        let done = await wait(q, good) { $0.isDone }
        XCTAssertEqual(done?.state.isFinished, true, "\(done?.log ?? [])")
        XCTAssertTrue(try String(contentsOf: master, encoding: .utf8).hasPrefix("args: render Demo"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: master.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Delivered-master.mp4"], "no partial files left behind")
    }

    func testPresetExtensionSwapNeverLandsOnAnExistingFile() throws {
        let gif = root.appendingPathComponent("demo.gif")
        try "keep".write(to: gif, atomically: true, encoding: .utf8)
        XCTAssertEqual(RenderQueue.unused(gif).lastPathComponent, "demo-2.gif")
        XCTAssertEqual(RenderQueue.unused(root.appendingPathComponent("fresh.gif")).lastPathComponent, "fresh.gif")
        XCTAssertEqual(RenderQueue.unused(root.appendingPathComponent("q.mp4"), taken: [root.appendingPathComponent("q.mp4").path])
                        .lastPathComponent, "q-2.mp4")
    }

    func testCancelQueuedJob() {
        let q = queue()
        _ = q.enqueue(scene: "A", preset: .preview, range: nil, build: .optimized, knobs: .saveToFile)
        let b = q.enqueue(scene: "B", preset: .preview, range: nil, build: .optimized, knobs: .saveToFile)
        q.cancel(b)
        XCTAssertEqual(q.job(b)?.state, .cancelled)
    }

    func testBuildFailureFailsTheJob() async {
        let q = RenderQueue(project: Project(root: root), resolveExecutable: { _, config, _ in
            throw RenderQueueError.build("\(config) build failed — Foo.swift:3: boom")
        }, ffmpeg: .some(nil))
        let id = q.enqueue(scene: "A", preset: .master1080p60, range: nil, build: .optimized, knobs: .saveToFile)
        let job = await wait(q, id) { $0.isDone }
        guard case .failed(let why) = job?.state else { return XCTFail() }
        XCTAssertTrue(why.contains("release build failed"))
    }

    func testAttachRenderToComment() async throws {
        let q = queue()
        let project = Project(root: root)
        let store = ReviewStore(project: project)
        let c = try store.add(scene: "Demo", ReviewComment(t: 1, body: "Check the outro", author: ReviewAuthor(name: "Sky")))
        XCTAssertEqual(q.attachableComments(scene: "Demo").map(\.id), [c.id])

        let id = q.enqueue(scene: "Demo", preset: .preview, range: nil, build: .optimized, knobs: .saveToFile)
        let job = await wait(q, id) { $0.isDone }
        XCTAssertEqual(job?.state.isFinished, true)
        let updated = try q.attach(id, toComment: c.id, author: "Sky")
        let att = try XCTUnwrap(updated.replies.last?.attachments.first)
        XCTAssertEqual(att.kind, .video)
        XCTAssertTrue(att.path.hasPrefix("out/Demo-preview-"), att.path)
        XCTAssertTrue(updated.replies.last!.body.contains("960×540"))
        XCTAssertEqual(try store.load(scene: "Demo").comments.first?.replies.count, 1)
    }
}

private extension RenderJob.State {
    var isFinished: Bool { if case .finished = self { return true }; return false }
}
