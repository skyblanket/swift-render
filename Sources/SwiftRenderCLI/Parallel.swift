import Foundation
import SwiftRender

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
@MainActor
func renderParallel(jobs: Int, scene: String, duration: Double, fps: Int,
                    audio: AudioSource, out: URL) async throws {
    let total = Int((duration * Double(fps)).rounded())
    let n = max(1, min(jobs, total / max(1, fps / 2)))   // keep chunks ≥ ~0.5 s
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-jobs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Forward every option except the ones this driver owns.
    var passthrough: [String] = []
    let argv = Array(CommandLine.arguments.dropFirst(3))
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--jobs", "--out", "--range": i += 2
        case "--open": i += 1
        default: passthrough.append(argv[i]); i += 1
        }
    }
    guard let exe = Bundle.main.executablePath else { throw NSError(domain: "jobs", code: 1) }

    var procs: [(Process, URL, URL)] = []
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
        let log = tmp.appendingPathComponent("chunk\(k).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardError = try FileHandle(forWritingTo: log)
        try p.run()
        procs.append((p, log, chunk))
    }
    print("[swift-render] \(n) jobs × ~\(total / n) frames")
    for (k, (p, log, _)) in procs.enumerated() {
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw NSError(domain: "jobs", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "chunk \(k) failed: \(msg.suffix(400))"])
        }
    }

    let plan = try AudioPlan.make(audio, fps: fps, needsTrack: false, needsMux: true)
    defer { plan.cleanup() }
    try await MP4Assembler.assemble(video: procs.map(\.2), audio: plan.muxURL, to: out)
}
