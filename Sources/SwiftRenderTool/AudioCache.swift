import CryptoKit
import Foundation
import SwiftRender
import SwiftRenderKit

// MARK: - Score audio cache
//
// A 90 s narrated score takes ~4.6 s to synthesize in a debug build, and Studio
// restarts its host after every rebuild. The host synthesizes once per
// fingerprint into <project>/.swift-render/cache/audio/<fp>.wav. The file is
// 32-bit float, so a hit decodes to exactly the samples ScoreSynth produced:
// audio-reactive frames from a hit match a fresh render bit for bit.

/// Synthesized score samples and the cached WAV that holds them.
struct ScoreAudio: Sendable {
    let fingerprint: String
    let wav: URL
    let left: [Float]
    let right: [Float]
    /// Decoded from disk rather than synthesized.
    let cacheHit: Bool

    /// Same mixdown as `AudioPlan`, so the analyzed track is identical.
    var mono: [Float] {
        var m = [Float](repeating: 0, count: left.count)
        for i in 0..<left.count { m[i] = (left[i] + right[i]) * 0.5 }
        return m
    }
}

enum AudioCache {
    /// Bump when ScoreSynth's output changes for identical events.
    static let synthVersion = 1

    static func directory(for project: Project?) -> URL {
        if let project { return project.cacheDir.appendingPathComponent("audio", isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("swift-render-audio", isDirectory: true)
    }

    /// SHA-256 of the events, the duration, and each resolved sample file's
    /// (path, size, mtime) — editing a foley file re-synthesizes; a rebuild that
    /// doesn't touch the score reuses the cache.
    static func fingerprint(_ score: Score) -> String {
        var text = "v\(synthVersion)|\(swiftRenderVersion)|\(score.duration)|\(String(reflecting: score.events))"
        let samples = Set(score.events.compactMap { e -> String? in
            if case .sample(let ref) = e.sound { return ref.path }; return nil
        })
        for path in samples.sorted() {
            guard let url = AssetPaths.resolve(path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                text += "|\(path):missing"; continue
            }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            text += "|\(url.path):\(size):\(mtime)"
        }
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func url(fingerprint: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(fingerprint).wav")
    }

    /// Cached WAV for this score if it exists (no synthesis).
    static func existing(_ score: Score, in dir: URL) -> URL? {
        let url = url(fingerprint: fingerprint(score), in: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decode the cached WAV, or synthesize and cache it. Blocking; any thread.
    static func load(_ score: Score, in dir: URL) throws -> ScoreAudio {
        let fp = fingerprint(score)
        let url = url(fingerprint: fp, in: dir)
        if let (l, r) = try? readFloatWAV(url) {
            return ScoreAudio(fingerprint: fp, wav: url, left: l, right: r, cacheHit: true)
        }
        let (l, r) = ScoreSynth.render(score)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write then rename: a second host (blue/green swap) may read the same path.
        let tmp = dir.appendingPathComponent(".\(fp)-\(getpid())-\(UUID().uuidString).wav")
        try writeFloatWAV(left: l, right: r, to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "AudioCache", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "cannot move cached audio into \(url.path): \(String(cString: strerror(errno)))"])
        }
        return ScoreAudio(fingerprint: fp, wav: url, left: l, right: r, cacheHit: false)
    }

    // MARK: 32-bit float WAV

    static func writeFloatWAV(left: [Float], right: [Float], to url: URL) throws {
        precondition(left.count == right.count)
        let n = left.count
        var data = Data(capacity: 58 + 8 * n)
        func tag(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(scoreSampleRate)
        tag("RIFF"); u32(UInt32(50 + 8 * n)); tag("WAVE")
        tag("fmt "); u32(18); u16(3); u16(2); u32(rate); u32(rate * 8); u16(8); u16(32); u16(0)
        tag("fact"); u32(4); u32(UInt32(n))
        tag("data"); u32(UInt32(8 * n))
        var interleaved = [Float](repeating: 0, count: 2 * n)
        for i in 0..<n { interleaved[2 * i] = left[i]; interleaved[2 * i + 1] = right[i] }
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }     // arm64/x86 are little-endian
        try data.write(to: url)
    }

    /// Reads back exactly what `writeFloatWAV` wrote (stereo float32 at the score rate).
    static func readFloatWAV(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func bad(_ why: String) -> NSError {
            NSError(domain: "AudioCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(why)"])
        }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        func u16(_ at: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) } }
        func tag(_ at: Int) -> String { String(decoding: data[at..<at + 4], as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw bad("not a WAV") }
        var off = 12
        var fmtOK = false
        while off + 8 <= data.count {
            let id = tag(off), size = Int(u32(off + 4))
            let body = off + 8
            if id == "fmt " {
                fmtOK = u16(body) == 3 && u16(body + 2) == 2 && u32(body + 4) == UInt32(scoreSampleRate) && u16(body + 14) == 32
            } else if id == "data" {
                guard fmtOK else { throw bad("not stereo float32 @ \(Int(scoreSampleRate)) Hz") }
                guard body + size <= data.count else { throw bad("truncated") }
                let n = size / 8
                var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
                data.withUnsafeBytes { raw in
                    for i in 0..<n {
                        l[i] = raw.loadUnaligned(fromByteOffset: body + 8 * i, as: Float.self)
                        r[i] = raw.loadUnaligned(fromByteOffset: body + 8 * i + 4, as: Float.self)
                    }
                }
                return (l, r)
            }
            off = body + size + (size & 1)
        }
        throw bad("no data chunk")
    }
}

// MARK: - Background audio analysis (host)

/// Everything the host learns about a scene's audio off the main thread.
struct AudioReady: Sendable {
    /// File Studio should play in sync.
    var path: String?
    /// Analyzed at the opened fps (what reactive scene bodies read).
    var track: AudioTrack
    var loudness: [Float]
    var captions: [CaptionInfo]
    var cacheHit: Bool
    var seconds: Double
}

extension AudioCache {
    /// Synthesize-or-load, analyze, and time the voiceover captions. Blocking; any thread.
    static func prepare(_ source: AudioSource, fps: Int, duration: Double, loudnessRate: Double,
                        cacheDir: URL) throws -> AudioReady {
        let start = Date()
        switch source {
        case .none:
            return AudioReady(path: nil, track: .silent, loudness: [], captions: [], cacheHit: false, seconds: 0)
        case .file(let url):
            let track = try AudioAnalyzer.analyze(url: url, fps: fps)
            return AudioReady(path: url.path, track: track,
                              loudness: loudnessEnvelope(track, duration: duration, rate: loudnessRate),
                              captions: [], cacheHit: true, seconds: Date().timeIntervalSince(start))
        case .score(let score):
            let audio = try load(score, in: cacheDir)
            let track = try AudioAnalyzer.analyze(samples: audio.mono, sampleRate: scoreSampleRate, fps: fps)
            // Speech lines are in the TTS cache by now, so this is cheap.
            let captions = CaptionTrack(score).cues.map { CaptionInfo(start: $0.start, end: $0.end, text: $0.text) }
            return AudioReady(path: audio.wav.path, track: track,
                              loudness: loudnessEnvelope(track, duration: duration, rate: loudnessRate),
                              captions: captions, cacheHit: audio.cacheHit, seconds: Date().timeIntervalSince(start))
        }
    }
}
