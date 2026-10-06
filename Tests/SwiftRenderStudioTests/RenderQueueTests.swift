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
        for i in 10 20 30; do
          printf '{"progress":{"frame":%d,"total":30,"fps":120.0}}\\n' $i >&2
          sleep ${FAKE_STEP:-0.05}
        done
        echo "args: $*" > "$out"
        echo "[swift-render] done in 0.2s → $out"
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    override func tearDown() async throws {
        unsetenv("FAKE_STEP"); unsetenv("FAKE_PARTIAL")
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "fake CLI wrote a partial file")
        let t0 = Date()
        q.cancel(id)
        let job = await wait(q, id, timeout: 8) { $0.isDone }
        XCTAssertEqual(job?.state, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "SIGINT ends the fake CLI right away")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
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
