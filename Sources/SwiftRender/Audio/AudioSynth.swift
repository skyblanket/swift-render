// AudioSynth.swift — deterministic offline PCM synthesis engine.
// Foundation + Accelerate only. 44.1 kHz stereo Float, 16-bit WAV out.
// Port of tools/make_launch_audio.py / make_kinetic_audio.py voice set.
import Foundation
import Accelerate

let SR: Float = 44_100

/// Sample rate of everything ScoreSynth produces.
public let scoreSampleRate: Double = 44_100

@inline(__always) func samples(_ dur: Float) -> Int { Int(dur * SR) }

// MARK: - Deterministic noise (same LCG as PostFX.swift's noise tile)

public struct NoiseLCG {
    private var state: UInt64
    public init(seed: UInt32) {
        // Same multiplier/increment as PostFX.makeNoiseTile; the seed is folded
        // into the fixed PostFX seed so every stream is reproducible.
        state = 0x9E37_79B9_7F4A_7C15 ^ (UInt64(seed) &* 0xD1B5_4A32_D192_ED03 &+ 1)
        state = state &* 6364136223846793005 &+ 1442695040888963407 // warm-up
    }
    public mutating func uniform() -> Float { // (0, 1), 24-bit mantissa
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Float(state >> 40) + 0.5) * (1.0 / 16_777_216.0)
    }
    public mutating func randn(_ n: Int) -> [Float] { // ~N(0,1), Box–Muller
        var out = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let r = (-2 * Foundation.log(uniform())).squareRoot()
            let th = 2 * Float.pi * uniform()
            out[i] = r * Foundation.cos(th); i += 1
            if i < n { out[i] = r * Foundation.sin(th); i += 1 }
        }
        return out
    }
    public static func randn(_ n: Int, seed: UInt32) -> [Float] {
        var g = NoiseLCG(seed: seed); return g.randn(n)
    }
}

// MARK: - DSP helpers

func ramp(_ n: Int, step: Float, start: Float = 0) -> [Float] {
    vDSP.ramp(withInitialValue: start, increment: step, count: n)
}
func envExp(_ n: Int, rate: Float) -> [Float] {          // exp(-t · rate)
    vForce.exp(ramp(n, step: -rate / SR))
}
func sweptSine(_ freq: [Float]) -> [Float] {             // sin(2π·cumsum(f)/SR)
    var phase = [Float](repeating: 0, count: freq.count)
    var acc = 0.0                                        // Double acc: no drift
    let k = 2.0 * Double.pi / Double(SR)
    for i in freq.indices {
        acc += Double(freq[i])
        phase[i] = Float((acc * k).truncatingRemainder(dividingBy: 2 * .pi))
    }
    return vForce.sin(phase)
}
func diff1(_ x: [Float]) -> [Float] {                    // np.diff(x, prepend=0)
    var out = x
    for i in stride(from: x.count - 1, through: 1, by: -1) { out[i] = x[i] - x[i - 1] }
    return out
}

// MARK: - Voices (pure functions → [Float])

public enum Voice {
    public static func kick(amp: Float = 1, sweep: (Float, Float) = (150, 44), dur: Float = 0.4) -> [Float] {
        let n = samples(dur)
        var freq = vDSP.multiply(sweep.0 - sweep.1, vForce.exp(ramp(n, step: -26 / SR)))
        vDSP.add(sweep.1, freq, result: &freq)
        var body = vDSP.multiply(sweptSine(freq), envExp(n, rate: 12))
        let click = vDSP.multiply(0.35, vDSP.multiply(NoiseLCG.randn(n, seed: 7), envExp(n, rate: 230)))
        vDSP.add(body, click, result: &body)
        return vDSP.multiply(amp, vForce.tanh(vDSP.multiply(2.3, body)))
    }

    public static func clap(amp: Float = 0.5, seed: UInt32 = 21) -> [Float] {
        let n = samples(0.28)
        var g = NoiseLCG(seed: seed)                     // one stream, 3 bursts
        var out = [Float](repeating: 0, count: n)
        for (k, off) in [Float(0), 0.011, 0.023].enumerated() {
            let i = samples(off), m = n - i
            let burst = vDSP.multiply(diff1(g.randn(m)), envExp(m, rate: k == 2 ? 70 : 220))
            for j in 0..<m { out[i + j] += burst[j] }
        }
        return vDSP.multiply(amp, out)
    }

    public static func hat(amp: Float = 0.1, dur: Float = 0.05, seed: UInt32 = 3) -> [Float] {
        let n = samples(dur)
        return vDSP.multiply(amp, vDSP.multiply(diff1(NoiseLCG.randn(n, seed: seed)), envExp(n, rate: 95)))
    }

    public static func crash(amp: Float = 0.3, dur: Float = 0.9, seed: UInt32 = 51) -> [Float] {
        let n = samples(dur)
        return vDSP.multiply(amp, vDSP.multiply(diff1(NoiseLCG.randn(n, seed: seed)), envExp(n, rate: 6)))
    }

    public static func bassNote(_ f: Float, amp: Float = 0.32, dur: Float = 0.5) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = vForce.sin(vDSP.multiply(2 * Float.pi * f, t))
        vDSP.add(sig, vDSP.multiply(0.35, vForce.sin(vDSP.multiply(4 * Float.pi * f, t))), result: &sig)
        sig = vForce.tanh(vDSP.multiply(1.6, sig))
        for i in 0..<n {                                  // 6 ms attack, 80 ms release
            let tt = Float(i) / SR
            sig[i] *= min(1, tt / 0.006) * max(0, min(1, (dur - tt) / 0.08)) * amp
        }
        return sig
    }

    public static func riser(amp: Float = 0.55, dur: Float = 3.4) -> [Float] {
        let n = samples(dur)
        var freq = [Float](repeating: 0, count: n)
        for i in 0..<n { let u = Float(i) / Float(n); freq[i] = 160 + (1500 - 160) * u * u }
        var sig = vDSP.multiply(0.55, NoiseLCG.randn(n, seed: 5))
        vDSP.add(sig, vDSP.multiply(0.45, sweptSine(freq)), result: &sig)
        for i in 0..<n { sig[i] *= Foundation.pow(Float(i) / Float(n), 2.4) * amp }
        return sig
    }

    public static func boom(amp: Float = 1, dur: Float = 2.6) -> [Float] {  // 808 drop
        let n = samples(dur)
        var freq = vDSP.multiply(32, vForce.exp(ramp(n, step: -13 / SR)))
        vDSP.add(36, freq, result: &freq)
        let sub = vDSP.multiply(sweptSine(freq), envExp(n, rate: 2.2))
        return vDSP.multiply(amp, vForce.tanh(vDSP.multiply(2.8, sub)))
    }

    public static func drone(amp: Float = 0.15, dur: Float = 7, f: Float = 55) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        let lfo = vDSP.add(0.7, vDSP.multiply(0.3, vForce.sin(vDSP.multiply(2 * Float.pi * 0.55, t))))
        var sig = vForce.sin(vDSP.multiply(2 * Float.pi * f, t))
        vDSP.add(sig, vDSP.multiply(0.5, vForce.sin(vDSP.add(0.7, vDSP.multiply(2 * Float.pi * f * 1.5, t)))), result: &sig)
        sig = vDSP.multiply(sig, lfo)
        for i in 0..<n {                                  // 0.8 s in / 1.2 s out
            let tt = Float(i) / SR
            sig[i] *= min(1, tt / 0.8) * max(0, min(1, (dur - tt) / 1.2)) * amp
        }
        return sig
    }

    public static func whoosh(amp: Float = 0.5, dur: Float = 0.7, rising: Bool = true, seed: UInt32 = 11) -> [Float] {
        let n = samples(dur)                              // moving-average filtered noise
        let noise = NoiseLCG.randn(n, seed: seed)
        var csum = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { csum[i + 1] = csum[i] + Double(noise[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let u = Float(i) / Float(n)
            let w = max(2, Int(rising ? 58 - 50 * u : 8 + 50 * u))
            let lo = max(0, i - w)
            let avg = Float((csum[i + 1] - csum[lo]) / Double(i + 1 - lo))
            out[i] = avg * Foundation.pow(max(0, Foundation.sin(.pi * u)), 1.5) * amp * 6
        }
        return out
    }
}

// MARK: - Event mixer: ducked music bus + clean kick bus, sidechain, master

public struct Mixer {
    public let n: Int
    var L: [Float], R: [Float]                            // music bus (ducked)
    var KL: [Float], KR: [Float]                          // clean bus (kicks/booms)
    public private(set) var kickTimes: [Double] = []

    public init(duration: Double) {
        n = Int(duration * Double(SR))
        L = [Float](repeating: 0, count: n); R = L; KL = L; KR = L
    }
    private static func mixInto(_ dst: inout [Float], _ src: [Float], at i: Int, count m: Int, gain: Float) {
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var g = gain                              // d[i..] += g · s  (vDSP_vsma)
                vDSP_vsma(s.baseAddress!, 1, &g, d.baseAddress! + i, 1, d.baseAddress! + i, 1, vDSP_Length(m))
            }
        }
    }
    /// Place a voice at `t` seconds. pan ∈ [-1, 1]; `clean` routes around the duck.
    public mutating func add(_ sig: [Float], at t: Double, pan: Float = 0, clean: Bool = false) {
        let i = Int(t * Double(SR))
        guard i >= 0, i < n else { return }
        let m = min(sig.count, n - i)
        guard m > 0 else { return }
        if clean {
            Self.mixInto(&KL, sig, at: i, count: m, gain: 1 - max(0, pan))
            Self.mixInto(&KR, sig, at: i, count: m, gain: 1 + min(0, pan))
        } else {
            Self.mixInto(&L, sig, at: i, count: m, gain: 1 - max(0, pan))
            Self.mixInto(&R, sig, at: i, count: m, gain: 1 + min(0, pan))
        }
    }
    /// Kick onto the clean bus; its onset also drives the sidechain pump.
    public mutating func addKick(_ sig: [Float], at t: Double, pan: Float = 0) {
        add(sig, at: t, pan: pan, clean: true)
        kickTimes.append(t)
    }

    /// duck → sum buses → tanh(×1.15) → fade-out → normalize to `peak`.
    public func master(fadeOut: Double = 1.2, peak: Float = 0.92) -> (left: [Float], right: [Float]) {
        var duck = [Float](repeating: 1, count: n)
        let dn = samples(0.42)
        let curve = (0..<dn).map { 1 - 0.5 * Foundation.exp(-Float($0) / SR / 0.11) }
        for t in kickTimes {
            let i0 = Int(t * Double(SR))
            for j in 0..<max(0, min(dn, n - i0)) { duck[i0 + j] = min(duck[i0 + j], curve[j]) }
        }
        func renderBus(_ music: [Float], _ clean: [Float]) -> [Float] {
            var ch = vDSP.multiply(music, duck)
            vDSP.add(ch, clean, result: &ch)
            return vForce.tanh(vDSP.multiply(1.15, ch))   // soft-clip master
        }
        var left = renderBus(L, KL), right = renderBus(R, KR)
        let fn = min(n, samples(Float(fadeOut)))
        for j in 0..<fn {                                  // linear fade to silence
            let g = Float(fn - 1 - j) / Float(max(1, fn - 1))
            left[n - fn + j] *= g; right[n - fn + j] *= g
        }
        let m = max(vDSP.maximumMagnitude(left), vDSP.maximumMagnitude(right))
        if m > 0 {
            left = vDSP.multiply(peak / m, left)
            right = vDSP.multiply(peak / m, right)
        }
        return (left, right)
    }
}

// MARK: - 16-bit PCM WAV writer

public enum WAV {
    public static func write(left: [Float], right: [Float], to url: URL) throws {
        precondition(left.count == right.count)
        let n = left.count
        var pcm = [Int16](repeating: 0, count: 2 * n)
        for i in 0..<n {                                   // interleave + clamp
            pcm[2 * i]     = Int16(max(-32767, min(32767, (left[i]  * 32767).rounded())))
            pcm[2 * i + 1] = Int16(max(-32767, min(32767, (right[i] * 32767).rounded())))
        }
        var data = Data(capacity: 44 + 4 * n)
        func tag(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        tag("RIFF"); u32(UInt32(36 + 4 * n)); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(2); u32(UInt32(SR)); u32(UInt32(SR) * 4); u16(4); u16(16)
        tag("data"); u32(UInt32(4 * n))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}