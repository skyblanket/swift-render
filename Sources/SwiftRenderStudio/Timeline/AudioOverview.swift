import AVFoundation
import Foundation
import Observation

// MARK: - Audio overview
//
// What the AUDIO lane draws from the scene's WAV: `WaveformMips` (min/max) and the
// silences `check` would report (0.5 s windows below −45 dBFS, ≥ 0.5 s long, not
// counting a silent start). Decoded off the main thread once per file + mtime.

struct AudioOverview: Sendable {
    let mips: WaveformMips
    let silences: [ClosedRange<Double>]
    let duration: Double

    static let silenceDB = -45.0
    static let window = 0.5

    static func load(url: URL) throws -> AudioOverview {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw NSError(domain: "AudioOverview", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty or unreadable audio"])
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        var meanSquare = [Float](repeating: 0, count: n)
        if let ch = buffer.floatChannelData {
            for c in 0..<channels {
                let p = ch[c]
                for i in 0..<n { let s = p[i]; mono[i] += s; meanSquare[i] += s * s }
            }
            let k = 1 / Float(max(1, channels))
            for i in 0..<n { mono[i] *= k; meanSquare[i] *= k }
        }
        let rate = buffer.format.sampleRate
        return AudioOverview(mips: WaveformMips(samples: mono, sampleRate: rate),
                             silences: silences(meanSquare: meanSquare, sampleRate: rate),
                             duration: Double(n) / rate)
    }

    /// Silent stretches, with `audioReport`'s windows and thresholds (`Check.swift`).
    static func silences(meanSquare ms: [Float], sampleRate rate: Double) -> [ClosedRange<Double>] {
        let win = max(1, Int(rate * window))
        var out: [ClosedRange<Double>] = []
        var silentStart: Double?
        var i = 0
        while i < ms.count {
            let e = min(ms.count, i + win)
            var s = 0.0
            for j in i..<e { s += Double(ms[j]) }
            let rms = (s / Double(e - i)).squareRoot()
            let level = rms > 0 ? 20 * log10(rms) : -200
            let t = Double(i) / rate
            if level < silenceDB {
                if silentStart == nil { silentStart = t }
            } else if let s0 = silentStart {
                if t - s0 >= window, s0 > 0.01 { out.append(s0...t) }
                silentStart = nil
            }
            i = e
        }
        return out
    }
}

/// Loaded overviews by path, shared by every window (the lane reads, never loads inline).
@MainActor @Observable
final class AudioOverviewCache {
    static let shared = AudioOverviewCache()

    private(set) var overviews: [String: AudioOverview] = [:]
    @ObservationIgnored private var stamps: [String: Date] = [:]
    @ObservationIgnored private var inFlight: [String: Task<AudioOverview?, Never>] = [:]
    /// Files that failed to decode, by mtime (not retried until they change).
    @ObservationIgnored private var failed: [String: Date?] = [:]

    /// The overview for `path` if loaded (current mtime); starts loading otherwise.
    func overview(_ path: String) -> AudioOverview? {
        let stamp = Self.mtime(path)
        if stamps[path] == stamp, let o = overviews[path] { return o }
        if inFlight[path] == nil, failed[path] != .some(stamp) { Task { await load(path) } }
        return overviews[path]          // the previous file's overview until the new one lands
    }

    /// Decode `path` (once per mtime) and publish it.
    @discardableResult
    func load(_ path: String) async -> AudioOverview? {
        let stamp = Self.mtime(path)
        if stamps[path] == stamp, let o = overviews[path] { return o }
        if let t = inFlight[path] { return await t.value }
        let task = Task.detached(priority: .utility) { try? AudioOverview.load(url: URL(fileURLWithPath: path)) }
        inFlight[path] = task
        let o = await task.value
        inFlight[path] = nil
        if let o { overviews[path] = o; stamps[path] = stamp; failed[path] = nil } else { failed[path] = .some(stamp) }
        return o
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
