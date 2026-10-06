import Foundation
import SwiftRender
import SwiftRenderKit

/// `render --jobs N`: split the frame range into N contiguous chunks, render each in
/// its own `swift-render` process (ImageRenderer is main-thread bound, so parallelism
/// has to be across processes), then stitch the chunks with MP4Assembler — video is
/// copied, not re-encoded — and mux the soundtrack once. Chunk frame times come from
/// absolute frame indices, so the result matches a single-process render frame for frame.
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
    let total: Int
    let start = Date()
    let emit: Bool

    init(chunks: Int, total: Int, emit: Bool) {
        done = Array(repeating: 0, count: chunks)
        logs = Array(repeating: Data(), count: chunks)
        partial = Array(repeating: Data(), count: chunks)
        self.total = total
        self.emit = emit
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
            guard emit, let p = try? HostWire.decode(RenderProgressLine.self, line: line) else { continue }
            done[k] = p.progress.frame
            let sum = done.reduce(0, +)
            guard sum != lastEmitted, sum % 10 == 0 || sum == total else { continue }
            lastEmitted = sum
            let fps = Double(sum) / max(1e-6, Date().timeIntervalSince(start))
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

@MainActor
func renderParallel(jobs: Int, scene: String, duration: Double, fps: Int,
                    audio: AudioSource, out: URL, argv: [String], progressJSON: Bool = false) async throws {
    let total = Int((duration * Double(fps)).rounded())
    let n = max(1, min(jobs, total / max(1, fps / 2)))   // keep chunks ≥ ~0.5 s
    if OutputPath.isDirectory(out) {
        throw OutputPathError("output path \(out.path) is a directory — refusing to replace it")
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-jobs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Forward every option except the ones this driver owns.
    let passthrough = chunkPassthrough(argv)
    guard let exe = Bundle.main.executablePath else { throw NSError(domain: "jobs", code: 1) }

    let progress = ChunkProgress(chunks: n, total: total, emit: progressJSON)
    var procs: [(Process, Pipe, URL)] = []
    for k in 0..<n {
        let a = total * k / n, b = total * (k + 1) / n
        let chunk = tmp.appendingPathComponent(String(format: "chunk%03d.mp4", k))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["render", scene] + passthrough + [
            "--range", String(format: "%.9f:%.9f", Double(a) / Double(fps), Double(b) / Double(fps)),
            "--out", chunk.path,
        ]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { progress.feed(k, d) }
        }
        p.standardError = err
        try p.run()
        procs.append((p, err, chunk))
    }
    print("[swift-render] \(n) jobs × ~\(total / n) frames")
    for (k, (p, err, _)) in procs.enumerated() {
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        let rest = err.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { progress.feed(k, rest) }
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "jobs", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "chunk \(k) failed: \(progress.log(k).suffix(400))"])
        }
    }

    let plan = try AudioPlan.make(audio, fps: fps, needsTrack: false, needsMux: true)
    defer { plan.cleanup() }
    try await MP4Assembler.assemble(video: procs.map(\.2), audio: plan.muxURL, to: out)
}
