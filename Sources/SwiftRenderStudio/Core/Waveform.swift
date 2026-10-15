import AVFoundation
import Accelerate
import Foundation

// MARK: - Waveform mips
//
// Min/max per 256-sample bucket from the score WAV, then ×4 mip levels, so drawing
// any zoom reads at most ~2 points per pixel from the level with ≥1 bucket per pixel.

struct WaveformMips: Sendable {
    let sampleRate: Double
    let bucketSize: Int
    /// levels[0] = 256-sample buckets; each next level merges 4.
    let levels: [[(min: Float, max: Float)]]
    let duration: Double

    init(url: URL, bucketSize: Int = 256) throws {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw NSError(domain: "Waveform", code: 1)
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: n)
        if let ch = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            for c in 0..<channels {
                vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(n))
            }
            var scale = 1 / Float(max(1, channels))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        }
        self.init(samples: mono, sampleRate: format.sampleRate, bucketSize: bucketSize)
    }

    init(samples: [Float], sampleRate: Double, bucketSize: Int = 256) {
        self.sampleRate = sampleRate
        self.bucketSize = bucketSize
        duration = Double(samples.count) / sampleRate
        var base: [(min: Float, max: Float)] = []
        base.reserveCapacity(samples.count / bucketSize + 1)
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i < samples.count {
                let len = min(bucketSize, samples.count - i)
                var lo: Float = 0, hi: Float = 0
                vDSP_minv(p.baseAddress! + i, 1, &lo, vDSP_Length(len))
                vDSP_maxv(p.baseAddress! + i, 1, &hi, vDSP_Length(len))
                base.append((lo, hi))
                i += bucketSize
            }
        }
        var levels = [base]
        while let last = levels.last, last.count > 64 {
            levels.append(stride(from: 0, to: last.count, by: 4).map { i in
                let s = last[i..<min(last.count, i + 4)]
                return (s.map(\.min).min() ?? 0, s.map(\.max).max() ?? 0)
            })
        }
        self.levels = levels
    }

    /// `buckets` min/max pairs covering [from, to] seconds.
    func peaks(from: Double, to: Double, buckets: Int) -> [(min: Float, max: Float)] {
        guard buckets > 0, to > from, let base = levels.first, !base.isEmpty else { return [] }
        let secondsPerBase = Double(bucketSize) / sampleRate
        let basePerOut = (to - from) / secondsPerBase / Double(buckets)
        var level = 0
        while level + 1 < levels.count, pow(4, Double(level + 1)) <= basePerOut { level += 1 }
        let lv = levels[level]
        let secondsPer = secondsPerBase * pow(4, Double(level))
        let span = (to - from) / Double(buckets)
        var out: [(min: Float, max: Float)] = []
        out.reserveCapacity(buckets)
        for b in 0..<buckets {
            // Split up so Swift 6.1 type-checks it in time.
            let start: Double = (from + Double(b) * span) / secondsPer
            let end: Double = (from + Double(b + 1) * span) / secondsPer
            let a = Int(start.rounded(.down))
            let z = max(a + 1, Int(end.rounded(.up)))
            let lo = max(0, a), hi = min(lv.count, z)
            guard lo < hi else { out.append((min: 0, max: 0)); continue }
            var mn: Float = 0, mx: Float = 0
            for i in lo..<hi { mn = min(mn, lv[i].min); mx = max(mx, lv[i].max) }
            out.append((min: mn, max: mx))
        }
        return out
    }
}
