import AVFoundation
import Accelerate

public enum AudioAnalyzerError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case empty(URL)
    case fftSetupFailed

    public var description: String {
        switch self {
        case .unreadable(let u, let why): return "cannot read audio \(u.path): \(why)"
        case .empty(let u):               return "audio file is empty: \(u.path)"
        case .fftSetupFailed:             return "vDSP FFT setup failed"
        }
    }
}

/// One-shot offline analysis: decode → per-frame windowed FFT → normalized,
/// smoothed envelopes. Runs once before the render loop; cost is one 2048-pt
/// FFT per output frame (sub-second for minutes of audio).
public enum AudioAnalyzer {

    /// - Parameters:
    ///   - fps: envelope sample rate; pass the render fps so lookups are exact per frame.
    ///   - windowSize: FFT window (power of two). 2048 @ 44.1 kHz ≈ 21.5 Hz/bin, ~46 ms.
    ///   - attack/release: one-pole smoothing time constants in seconds (visual stability).
    public static func analyze(
        url: URL,
        fps: Int,
        windowSize: Int = 2048,
        attack: Double = 0.03,
        release: Double = 0.25
    ) throws -> AudioTrack {
        precondition(fps > 0 && windowSize > 1 && (windowSize & (windowSize - 1)) == 0,
                     "windowSize must be a power of two")

        // ---- 1. Decode to mono Float32 -----------------------------------
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw AudioAnalyzerError.unreadable(url, error.localizedDescription) }

        let format = file.processingFormat            // always float32, deinterleaved
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)
        else { throw AudioAnalyzerError.empty(url) }
        try file.read(into: buf)

        let n = Int(buf.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if let data = buf.floatChannelData {
            for c in 0..<channels {
                vDSP_vadd(mono, 1, data[c], 1, &mono, 1, vDSP_Length(n))
            }
            var inv = 1 / Float(channels)
            vDSP_vsmul(mono, 1, &inv, &mono, 1, vDSP_Length(n))
        }

        let sr = format.sampleRate
        let duration = Double(n) / sr
        let frameTotal = max(1, Int((duration * Double(fps)).rounded(.up)))

        // ---- 2. FFT setup -------------------------------------------------
        let half = windowSize / 2
        let log2n = vDSP_Length(windowSize.trailingZeroBitCount)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        else { throw AudioAnalyzerError.fftSetupFailed }

        var hann = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hann, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        let binHz = sr / Double(windowSize)
        let nyquist = sr / 2
        // Precompute inclusive bin ranges per band (skip bin 0: packed DC/Nyquist).
        let bandBins: [(AudioTrack.Band, ClosedRange<Int>)] = AudioTrack.Band.allCases.compactMap { b in
            let lo = max(1, Int(b.hzRange.lowerBound / binHz))
            let hi = min(half - 1, Int(min(b.hzRange.upperBound, nyquist) / binHz))
            return lo <= hi ? (b, lo...hi) : nil
        }

        // ---- 3. Per-frame windowed FFT ------------------------------------
        var rms = [Float](repeating: 0, count: frameTotal)
        var raws: [AudioTrack.Band: [Float]] = Dictionary(
            uniqueKeysWithValues: AudioTrack.Band.allCases.map { ($0, [Float](repeating: 0, count: frameTotal)) }
        )

        var windowed = [Float](repeating: 0, count: windowSize)
        var realIn  = [Float](repeating: 0, count: half)
        var imagIn  = [Float](repeating: 0, count: half)
        var realOut = [Float](repeating: 0, count: half)
        var imagOut = [Float](repeating: 0, count: half)
        var mags    = [Float](repeating: 0, count: half)

        for f in 0..<frameTotal {
            // Window centered on this frame's timestamp; zero-padded at edges.
            let center = Int((Double(f) / Double(fps)) * sr)
            let start = center - half
            for k in 0..<windowSize {
                let s = start + k
                windowed[k] = (s >= 0 && s < n) ? mono[s] : 0
            }

            var r: Float = 0
            vDSP_rmsqv(windowed, 1, &r, vDSP_Length(windowSize))
            rms[f] = r

            vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(windowSize))

            // Pack real signal into split-complex, forward FFT, magnitudes.
            windowed.withUnsafeBytes { raw in
                let cplx = raw.bindMemory(to: DSPComplex.self)
                realIn.withUnsafeMutableBufferPointer { rp in
                    imagIn.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
            realOut.withUnsafeMutableBufferPointer { rop in
                imagOut.withUnsafeMutableBufferPointer { iop in
                    realIn.withUnsafeMutableBufferPointer { rip in
                        imagIn.withUnsafeMutableBufferPointer { iip in
                            let input = DSPSplitComplex(realp: rip.baseAddress!, imagp: iip.baseAddress!)
                            var output = DSPSplitComplex(realp: rop.baseAddress!, imagp: iop.baseAddress!)
                            fft.forward(input: input, output: &output)
                            vDSP_zvmags(&output, 1, &mags, 1, vDSP_Length(half))
                        }
                    }
                }
            }
            for (band, bins) in bandBins {
                var sum: Float = 0
                mags.withUnsafeBufferPointer { p in
                    vDSP_sve(p.baseAddress! + bins.lowerBound, 1, &sum,
                             vDSP_Length(bins.count))
                }
                raws[band]![f] = sqrt(sum / Float(bins.count))   // band RMS magnitude
            }
        }

        // ---- 4. Normalize (p95) + attack/release smoothing ----------------
        let dt = 1.0 / Double(fps)
        func finish(_ env: [Float]) -> [Float] {
            var e = normalizeP95(env)
            let aC = attack  > 0 ? Float(exp(-dt / attack))  : 0
            let rC = release > 0 ? Float(exp(-dt / release)) : 0
            var y: Float = 0
            for i in e.indices {
                let c = e[i] > y ? aC : rC
                y = c * y + (1 - c) * e[i]
                e[i] = y
            }
            return e
        }

        return AudioTrack(
            fps: fps,
            duration: duration,
            rmsEnv: finish(rms),
            bandEnvs: raws.mapValues(finish)
        )
    }

    /// Scale so the 95th percentile maps to 1.0 (robust to one-off transients),
    /// then clamp to 0…1. Per-track relative loudness, not absolute dBFS.
    private static func normalizeP95(_ env: [Float]) -> [Float] {
        guard !env.isEmpty else { return env }
        let sorted = env.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        guard p95 > 1e-6 else { return [Float](repeating: 0, count: env.count) }
        return env.map { min(1, $0 / p95) }
    }
}
