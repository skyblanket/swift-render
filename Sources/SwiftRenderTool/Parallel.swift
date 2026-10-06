import Foundation
import SwiftRender
import SwiftRenderKit

/// `render --jobs N`: split the frame range into contiguous pieces, render them in a pool of
/// N `swift-render` processes (ImageRenderer is main-thread bound, so parallelism has to be
/// across processes), then stitch the pieces with MP4Assembler — video is copied, not
/// re-encoded — and mux the soundtrack once. Piece frame times come from absolute frame
/// indices, so the result matches a single-process render frame for frame.
///
/// There are up to 4 pieces per process, each at least ~0.5 s, and a process takes the next
/// piece as soon as it finishes one. Frames cost very different amounts across a film (one
/// heavy stretch can hold half the work), so equal-sized slices per process left one process
/// rendering alone at the end — slower, and a progress estimate that said "almost done"
/// for most of the render.
///
/// `--jobs auto` uses half the logical cores: each process already keeps several
/// threads busy (SwiftUI layout, CoreImage, the H.264 encoder).
func resolveJobs(_ raw: String) -> Int {
    if raw == "auto" { return max(2, ProcessInfo.processInfo.activeProcessorCount / 2) }
    return max(1, Int(raw) ?? 1)
}
/// Arguments the `--jobs` driver forwards to each chunk process: everything after
/// `<subcommand> <scene>` except the options the driver owns (`--jobs`, `--out`,
/// `--range`, `--open`). Built from the argv the command was *invoked with* — not
/// `CommandLine.arguments`, which differs when a host calls `SwiftRenderCommand.main(arguments:)`.
func chunkPassthrough(_ argv: [String]) -> [String] {
    var passthrough: [String] = []
    let tail = Array(argv.dropFirst(3))
    var i = 0
    while i < tail.count {
        switch tail[i] {
        case "--jobs", "--out", "--range": i += 2
        case "--open": i += 1
        default: passthrough.append(tail[i]); i += 1
        }
    }
    return passthrough
}

/// Sums the chunks' `--progress json` lines into one progress stream for the whole render.
private final class ChunkProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var done: [Int]
    private var logs: [Data]
    private var partial: [Data]
    private var lastEmitted = -1
    private var forwardedAudio = false
    private var forwardedRender = false
    private var firstFrame: Date?
    private var firstSum = 0
    let total: Int
    let emit: Bool
    /// Detail for the one `render` stage line the driver sends ("4 parts").
    let renderDetail: String

    init(chunks: Int, total: Int, emit: Bool, renderDetail: String) {
        done = Array(repeating: 0, count: chunks)
        logs = Array(repeating: Data(), count: chunks)
        partial = Array(repeating: Data(), count: chunks)
        self.total = total
        self.emit = emit
        self.renderDetail = renderDetail
    }

    /// Bytes from chunk `k`'s stderr: kept for error reports; progress lines are summed.
    func feed(_ k: Int, _ data: Data) {
        lock.lock()
        logs[k].append(data)
        partial[k].append(data)
        var lines: [Data] = []
        while let nl = partial[k].firstIndex(of: 0x0A) {
            lines.append(partial[k][partial[k].startIndex..<nl])
            partial[k] = Data(partial[k][(nl + 1)...])
        }
        var out: Data? = nil
        for line in lines {
            guard emit else { continue }
            // Stages, in a single process's order: the first chunk's `audio` (every chunk
            // synthesizes an audio-reactive scene's track; say so once), then its `render`.
            // Chunks' own `mux` lines are per-part; the driver sends the real one after stitching.
            if let st = try? HostWire.decode(RenderStageLine.self, line: line) {
                guard lastEmitted < 0 else { continue }
                var forward: RenderStageLine?
                switch st.stage {
                case .audio where !forwardedAudio && !forwardedRender:
                    forwardedAudio = true; forward = st
                case .render where !forwardedRender:
                    forwardedRender = true; forward = RenderStageLine(.render, renderDetail)
                default: break
                }
                if let forward, let encoded = try? HostWire.encode(forward) { out = (out ?? Data()) + encoded }
                continue
            }
            guard let p = try? HostWire.decode(RenderProgressLine.self, line: line) else { continue }
            done[k] = p.progress.frame
            let sum = done.reduce(0, +)
            // Throughput from the first progress line on (chunk start-up isn't render speed);
            // 0 until there's a second's worth of evidence.
            if firstFrame == nil { firstFrame = Date(); firstSum = sum }
            // Every 10 frames of the *sum*: chunks report every 10 of their own but end on
            // odd counts, so gating on `sum % 10` would go quiet once the first chunk finished.
            guard sum > lastEmitted, sum - max(0, lastEmitted) >= 10 || sum == total else { continue }
            lastEmitted = sum
            let elapsed = Date().timeIntervalSince(firstFrame ?? Date())
            let fps = elapsed < 1 ? 0 : Double(sum - firstSum) / elapsed
            if let encoded = try? HostWire.encode(RenderProgressLine(frame: sum, total: total, fps: (fps * 10).rounded() / 10)) {
                out = (out ?? Data()) + encoded
            }
        }
        lock.unlock()
        if let out { FileHandle.standardError.write(out) }
    }

    func log(_ k: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: logs[k], as: UTF8.self)
    }
}

/// The chunk processes and scratch directory of one `--jobs` render, so they can be torn
/// down from a signal handler: Stop in Studio (SIGINT/SIGTERM to the driver) or Ctrl-C must
/// not leave chunks rendering in their own process groups, or partial chunks in $TMPDIR.
private final class ChunkSet: @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [Process] = []
    private var aborted = false
    let tmp: URL

    init(tmp: URL) { self.tmp = tmp }

    /// Registers a started chunk; one that started after an abort is stopped at once.
    func add(_ p: Process) {
        lock.lock()
        procs.append(p)
        let late = aborted
        lock.unlock()
        if late { p.terminate() }
    }

    /// Stops every chunk still running: SIGTERM, then SIGKILL after a second.
    func terminateAll() {
        lock.lock()
        aborted = true
        let running = procs.filter(\.isRunning)
        lock.unlock()
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while running.contains(where: \.isRunning), Date() < deadline { usleep(20_000) }
        for p in running where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for p in running { p.waitUntilExit() }
    }

    var isAborted: Bool { lock.lock(); defer { lock.unlock() }; return aborted }

    /// Signal path: stop the chunks, delete the scratch directory, exit like the signal would.
    func abort(signal sig: Int32) -> Never {
        lock.lock(); aborted = true; lock.unlock()
        terminateAll()
        try? FileManager.default.removeItem(at: tmp)
        exit(128 + sig)
    }
}

@MainActor
func renderParallel(jobs: Int, scene: String, duration: Double, fps: Int,
                    audio: AudioSource, out: URL, argv: [String], progressJSON: Bool = false) async throws {
    let total = Int((duration * Double(fps)).rounded())
    let minPiece = max(1, fps / 2)                                   // keep pieces ≥ ~0.5 s
    let pieces = max(1, min(jobs * 4, total / minPiece))
    let n = max(1, min(jobs, pieces))
    if OutputPath.isDirectory(out) {
        throw OutputPathError("output path \(out.path) is a directory — refusing to replace it")
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-jobs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let chunks = ChunkSet(tmp: tmp)
    // A failed chunk (or a thrown error) stops its siblings rather than leaving them rendering.
    defer { chunks.terminateAll() }
    // SIGINT/SIGTERM: the default action would skip every `defer` above.
    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
        src.setEventHandler { chunks.abort(signal: sig) }
        src.resume()
        return src
    }
    defer {
        signals.forEach { $0.cancel() }
        signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL)
    }

    // Forward every option except the ones this driver owns.
    let passthrough = chunkPassthrough(argv)
    guard let exe = Bundle.main.executablePath else { throw NSError(domain: "jobs", code: 1) }

    // Stage lines come from the chunks (forwarded once each, in order), so an audio-reactive
    // scene reads "music" before "render" exactly as in a single process.
    let progress = ChunkProgress(chunks: pieces, total: total, emit: progressJSON,
                                 renderDetail: "\(pieces) parts on \(n) processes")
    // The soundtrack for the final mux is synthesized while the chunks render.
    let planTask = Task.detached(priority: .utility) {
        try AudioPlan.make(audio, fps: fps, needsTrack: false, needsMux: true, announce: false, tempDir: tmp)
    }
    let pieceURLs = (0..<pieces).map { tmp.appendingPathComponent(String(format: "chunk%03d.mp4", $0)) }
    let pool = PiecePool(count: pieces)
    let group = DispatchGroup()
    for _ in 0..<n {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while let k = pool.next() {
                let a = total * k / pieces, b = total * (k + 1) / pieces
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["render", scene] + passthrough + [
                    "--range", String(format: "%.9f:%.9f", Double(a) / Double(fps), Double(b) / Double(fps)),
                    "--out", pieceURLs[k].path,
                ]
                p.standardOutput = FileHandle.nullDevice
                let err = Pipe()
                err.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { progress.feed(k, d) }
                }
                p.standardError = err
                do { try p.run() } catch {
                    pool.fail(k, "could not start: \(error)"); chunks.terminateAll(); return
                }
                chunks.add(p)
                p.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                let rest = err.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { progress.feed(k, rest) }
                guard p.terminationStatus == 0 else {
                    // Fail fast: stop every other piece now rather than when the loop reaches it.
                    if !chunks.isAborted { pool.fail(k, String(progress.log(k).suffix(400))); chunks.terminateAll() }
                    return
                }
            }
        }
    }
    print("[swift-render] \(n) jobs × \(pieces) pieces of ~\(total / pieces) frames")
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) { done.resume() }
    }
    if let failure = pool.failure {
        throw NSError(domain: "jobs", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "piece \(failure.piece + 1) of \(pieces) failed: \(failure.reason)"])
    }
    // Stopped by a signal (no piece failed on its own): the handler is tearing down and exits
    // with the signal's status; don't race it by stitching or reporting an error.
    if chunks.isAborted { while true { sleep(1) } }

    let plan = try await planTask.value
    defer { plan.cleanup() }
    StageReporter.emit(.mux, "Joining \(pieces) parts")
    try await MP4Assembler.assemble(video: pieceURLs, audio: plan.muxURL, to: out)
}

/// Hands out piece indices in order to the worker threads and records the first failure.
private final class PiecePool: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = 0
    private let count: Int
    private(set) var failure: (piece: Int, reason: String)?

    init(count: Int) { self.count = count }

    /// The next piece to render, or nil when all are taken or one has failed.
    func next() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, cursor < count else { return nil }
        defer { cursor += 1 }
        return cursor
    }

    func fail(_ piece: Int, _ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = (piece, reason.isEmpty ? "exited with an error" : reason) }
    }
}
