//
//  Samples.swift — audio files as Score events: foley, stems, the sound of a
//  video clip. Decoded once to 44.1 kHz stereo float and cached, so renders stay
//  deterministic and fast.
//
import AVFoundation
import Foundation

/// An audio file the Score plays. Anything AVAudioFile reads works: wav, aiff,
/// caf, m4a, mp3, and the audio track of mp4/mov.
public struct SampleRef: Sendable, Hashable {
    /// File path, resolved against cwd, assets/ and the package root.
    public var path: String
    /// Varispeed: 2 = an octave up and twice as fast. Small offsets (0.95…1.05)
    /// keep repeated one-shots from sounding identical.
    public var rate: Double
    /// Seconds into the file to start playing.
    public var offset: Double

    /// Creates a reference to the file at `path`.
    public init(_ path: String, rate: Double = 1, offset: Double = 0) {
        self.path = path; self.rate = rate; self.offset = offset
    }
}

/// Decoded audio at `scoreSampleRate`, stereo.
public struct SampleBuffer: Sendable {
    /// Left-channel samples.
    public let left: [Float]
    /// Right-channel samples.
    public let right: [Float]
    /// Number of sample frames per channel.
    public var frames: Int { left.count }
    /// Length in seconds.
    public var duration: Double { Double(left.count) / scoreSampleRate }
    /// A buffer with no samples.
    public static let empty = SampleBuffer(left: [], right: [])
}

/// Errors thrown when a sample file can't be found or decoded.
public enum SampleError: Error, CustomStringConvertible {
    case notFound(String)
    case unreadable(String, String)

    /// Human-readable error message.
    public var description: String {
        switch self {
        case .notFound(let p): return "sample not found: \(p) (searched cwd, assets/, package root)"
        case .unreadable(let p, let why): return "cannot decode \(p): \(why)"
        }
    }
}

/// Loads, caches and shapes the audio files that Score samples play.
public enum SampleLibrary {
    private static let cache = LockedCache<String, SampleBuffer>()

    /// Load (and cache) a sample by scene-relative path.
    public static func load(_ path: String) throws -> SampleBuffer {
        guard let url = AssetPaths.resolve(path) else { throw SampleError.notFound(path) }
        return try load(url: url)
    }

    /// Load (and cache, until the file changes) a sample by URL.
    public static func load(url: URL) throws -> SampleBuffer {
        let path = url.standardizedFileURL.path
        // Versioned by the file's stamp: an edited sample is decoded again (AudioCache's
        // fingerprint already changed), never served from the old decode.
        return try cache.value(path, version: FileStamp.of(path)) { try decode(url) }
    }

    static func decode(_ url: URL) throws -> SampleBuffer {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw SampleError.unreadable(url.path, error.localizedDescription) }
        let inFmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { return .empty }
        do { try file.read(into: inBuf) }
        catch { throw SampleError.unreadable(url.path, error.localizedDescription) }

        let channels = min(2, Int(inFmt.channelCount))
        var buf = inBuf
        if inFmt.sampleRate != scoreSampleRate || inFmt.channelCount > 2 {
            guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: scoreSampleRate,
                                             channels: AVAudioChannelCount(channels)),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt)
            else { throw SampleError.unreadable(url.path, "no converter for \(inFmt)") }
            conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            let cap = AVAudioFrameCount(Double(frames) * scoreSampleRate / inFmt.sampleRate + 4096)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return .empty }
            let fed = ResultBox<Bool>()
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
                if fed.value == true { inStatus.pointee = .endOfStream; return nil }
                fed.value = true
                inStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw SampleError.unreadable(url.path, err?.localizedDescription ?? "convert failed") }
            buf = outBuf
        }
        guard let data = buf.floatChannelData else { throw SampleError.unreadable(url.path, "not float PCM") }
        let n = Int(buf.frameLength)
        let l = Array(UnsafeBufferPointer(start: data[0], count: n))
        let r = channels > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : l
        return SampleBuffer(left: l, right: r)
    }

    /// `buffer` from `offset`, varispeed by `rate`, trimmed to `duration` (0 = all)
    /// with a short tail fade so trims never click.
    static func shaped(_ b: SampleBuffer, rate: Double, offset: Double, duration: Double) -> SampleBuffer {
        let start = max(0, min(b.frames, Int(offset * scoreSampleRate)))
        let available = Double(b.frames - start) / max(rate, 1e-6)
        var outN = Int(available)
        if duration > 0 { outN = min(outN, Int(duration * scoreSampleRate)) }
        guard outN > 0 else { return .empty }
        var l = [Float](repeating: 0, count: outN), r = l
        if rate == 1 {
            for i in 0..<outN { l[i] = b.left[start + i]; r[i] = b.right[start + i] }
        } else {
            for i in 0..<outN {
                let p = Double(start) + Double(i) * rate
                let i0 = Int(p), f = Float(p - Double(i0))
                let i1 = min(b.frames - 1, i0 + 1)
                l[i] = b.left[i0] * (1 - f) + b.left[i1] * f
                r[i] = b.right[i0] * (1 - f) + b.right[i1] * f
            }
        }
        if duration > 0 {
            let fade = min(outN, Int(0.012 * scoreSampleRate))
            for k in 0..<fade {
                let g = Float(k) / Float(max(1, fade))
                l[outN - 1 - k] *= g; r[outN - 1 - k] *= g
            }
        }
        return SampleBuffer(left: l, right: r)
    }
}
