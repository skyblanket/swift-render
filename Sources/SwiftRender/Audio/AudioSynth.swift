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

// MARK: - Melodic voices (pluck / bell / pad / chip / triangle bass / laser)

extension Voice {
    /// Feedback echo baked into the voice tail (cheap space, fully deterministic).
    static func echo(_ x: [Float], delay: Float, feedback: Float, taps: Int) -> [Float] {
        let d = samples(delay)
        var out = x + [Float](repeating: 0, count: d * taps)
        for k in 1...max(1, taps) {
            let g = Foundation.pow(feedback, Float(k))
            for i in 0..<x.count { out[i + d * k] += x[i] * g }
        }
        return out
    }

    /// Soft kalimba-ish pluck: four decaying harmonics + dotted-eighth echo.
    public static func pluck(_ f: Float, amp: Float = 0.16, dur: Float = 0.9) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = [Float](repeating: 0, count: n)
        for (k, a, r) in [(Float(1), Float(1), Float(3.2)), (2, 0.42, 6), (3, 0.2, 9), (4, 0.08, 13)] where f * k < 9000 {
            let h = vDSP.multiply(vForce.sin(vDSP.multiply(2 * Float.pi * f * k, t)),
                                  vForce.exp(vDSP.multiply(-r, t)))
            vDSP.add(sig, vDSP.multiply(a, h), result: &sig)
        }
        let atk = samples(0.004)
        for i in 0..<min(n, atk) { sig[i] *= Float(i) / Float(atk) }
        return echo(vDSP.multiply(amp, sig), delay: 0.234, feedback: 0.33, taps: 3)
    }

    /// FM bell (inharmonic 3.5 ratio, index decays) with a longer echo.
    public static func bell(_ f: Float, amp: Float = 0.13, dur: Float = 1.6) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        let idx = vDSP.multiply(2.0, vForce.exp(vDSP.multiply(-3.2, t)))
        let mod = vDSP.multiply(idx, vForce.sin(vDSP.multiply(2 * Float.pi * f * 3.5, t)))
        let arg = vDSP.add(vDSP.multiply(2 * Float.pi * f, t), mod)
        var sig = vDSP.multiply(vForce.sin(arg), vForce.exp(vDSP.multiply(-2.2, t)))
        let atk = samples(0.003)
        for i in 0..<min(n, atk) { sig[i] *= Float(i) / Float(atk) }
        let rel = samples(0.12)
        for i in 0..<min(n, rel) { sig[n - 1 - i] *= Float(i) / Float(rel) }
        return echo(vDSP.multiply(amp, sig), delay: 0.352, feedback: 0.38, taps: 3)
    }

    /// Slow, warm pad: two detuned stacks of three harmonics, long attack/release.
    public static func pad(_ f: Float, amp: Float = 0.04, dur: Float = 2) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = [Float](repeating: 0, count: n)
        for det in [Float(0.997), 1.003] {
            for (k, a) in [(Float(1), Float(1)), (2, 0.32), (3, 0.1)] {
                let h = vForce.sin(vDSP.multiply(2 * Float.pi * f * det * k, t))
                vDSP.add(sig, vDSP.multiply(a, h), result: &sig)
            }
        }
        let trem = vDSP.add(0.9, vDSP.multiply(0.1, vForce.sin(vDSP.multiply(2 * Float.pi * 0.27, t))))
        sig = vDSP.multiply(sig, trem)
        let attack: Float = min(0.7, dur * 0.35), release: Float = min(0.9, dur * 0.4)
        for i in 0..<n {
            let tt = Float(i) / SR
            sig[i] *= min(1, tt / attack) * max(0, min(1, (dur - tt) / release)) * amp
        }
        return sig
    }

    /// Band-limited 25% pulse — the "chip" blip, with a short echo.
    public static func chip(_ f: Float, amp: Float = 0.1, dur: Float = 0.18) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = [Float](repeating: 0, count: n)
        for k in 1...8 where f * Float(k) < 7000 {
            let a = 2 / (Float(k) * Float.pi) * Foundation.sin(Float(k) * Float.pi * 0.25)
            vDSP.add(sig, vDSP.multiply(a, vForce.cos(vDSP.multiply(2 * Float.pi * f * Float(k), t))), result: &sig)
        }
        let env = vForce.exp(vDSP.multiply(-11, t))
        sig = vDSP.multiply(sig, env)
        let atk = samples(0.002)
        for i in 0..<min(n, atk) { sig[i] *= Float(i) / Float(atk) }
        return echo(vDSP.multiply(amp, sig), delay: 0.117, feedback: 0.3, taps: 2)
    }

    /// Round triangle bass with a gentle decay, no tanh crunch.
    public static func triBass(_ f: Float, amp: Float = 0.3, dur: Float = 0.5) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = [Float](repeating: 0, count: n)
        for (i, k) in [Float(1), 3, 5, 7].enumerated() {
            let a = (i % 2 == 0 ? 1 : -1) / (k * k)
            vDSP.add(sig, vDSP.multiply(a, vForce.sin(vDSP.multiply(2 * Float.pi * f * k, t))), result: &sig)
        }
        for i in 0..<n {
            let tt = Float(i) / SR
            sig[i] *= min(1, tt / 0.01) * max(0, min(1, (dur - tt) / 0.07)) * Foundation.exp(-tt * 0.9) * amp
        }
        return sig
    }

    /// Descending pulse chirp — "pew".
    public static func laser(amp: Float = 0.2, dur: Float = 0.2) -> [Float] {
        let n = samples(dur)
        var freq = [Float](repeating: 0, count: n)
        for i in 0..<n { freq[i] = 1700 * Foundation.pow(0.16, Float(i) / Float(n)) }
        var sig = sweptSine(freq)
        vDSP.add(sig, vDSP.multiply(0.35, sweptSine(vDSP.multiply(2, freq))), result: &sig)
        sig = vDSP.multiply(sig, envExp(n, rate: 14))
        let atk = samples(0.002)
        for i in 0..<min(n, atk) { sig[i] *= Float(i) / Float(atk) }
        return vDSP.multiply(amp, sig)
    }
}

// MARK: - Texture voices

extension Voice {
    /// Vinyl crackle: sparse decaying pops + a little surface hiss, faded in/out.
    /// Returns a decorrelated stereo pair.
    public static func crackle(amp: Float = 0.04, dur: Float = 4, seed: UInt32 = 71) -> ([Float], [Float]) {
        let n = samples(dur)
        guard n > 0 else { return ([], []) }
        var g = NoiseLCG(seed: seed)
        var x = [Float](repeating: 0, count: n)
        let popRate = 38.0 / Double(SR)
        for i in 0..<n where Double(g.uniform()) < popRate {
            let a = -Foundation.log(g.uniform()) * 0.35 * (g.uniform() < 0.5 ? -1 : 1)
            for k in 0..<24 where i + k < n { x[i + k] += a * Foundation.exp(-Float(k) / 4) }
        }
        x = diff1(x)
        let hiss = NoiseLCG.randn(n, seed: seed &+ 1)
        for i in 0..<n { x[i] += hiss[i] * 0.012 }
        let peak = max(1e-6, vDSP.maximumMagnitude(x))
        let fade = min(n / 2, samples(0.6))
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            var e: Float = 1
            if i < fade { e = Float(i) / Float(fade) } else if i >= n - fade { e = Float(n - 1 - i) / Float(fade) }
            l[i] = x[i] / peak * amp * e
            r[i] = x[(i + 37) % n] / peak * amp * e
        }
        return (l, r)
    }
}

// MARK: - Transition marks (tick / rim / thump / blip / swell) — tonal, no noise

extension Voice {
    static func fadeIn(_ sig: inout [Float], _ seconds: Float) {
        let n = min(sig.count, samples(seconds))
        for i in 0..<n { sig[i] *= Float(i) / Float(max(1, n)) }
    }

    /// Woodblock tick: two inharmonic partials, gone in ~60 ms.
    public static func tick(amp: Float = 0.18, pitch: Float = 1850) -> [Float] {
        let n = samples(0.07)
        let t = ramp(n, step: 1 / SR)
        var sig = vDSP.multiply(vForce.sin(vDSP.multiply(2 * Float.pi * pitch, t)), envExp(n, rate: 85))
        let upper = vDSP.multiply(vForce.sin(vDSP.multiply(2 * Float.pi * pitch * 1.52, t)), envExp(n, rate: 140))
        vDSP.add(sig, vDSP.multiply(0.5, upper), result: &sig)
        fadeIn(&sig, 0.001)
        return vDSP.multiply(amp, sig)
    }

    /// Rim knock: 430 Hz body + 1.7 kHz ping, lightly saturated.
    public static func rim(amp: Float = 0.22) -> [Float] {
        let n = samples(0.10)
        let t = ramp(n, step: 1 / SR)
        var sig = vDSP.multiply(vForce.sin(vDSP.multiply(2 * Float.pi * 430, t)), envExp(n, rate: 55))
        let ping = vDSP.multiply(vForce.sin(vDSP.multiply(2 * Float.pi * 1720, t)), envExp(n, rate: 120))
        vDSP.add(sig, vDSP.multiply(0.6, ping), result: &sig)
        sig = vForce.tanh(vDSP.multiply(1.4, sig))
        fadeIn(&sig, 0.001)
        return vDSP.multiply(amp, sig)
    }

    /// Felt thump: a sine falling 135 → 58 Hz with a 3 ms attack — low, round, no click.
    public static func thump(amp: Float = 0.5) -> [Float] {
        let n = samples(0.30)
        var freq = vDSP.multiply(77, vForce.exp(ramp(n, step: -30 / SR)))
        vDSP.add(58, freq, result: &freq)
        var sig = vDSP.multiply(sweptSine(freq), envExp(n, rate: 14))
        fadeIn(&sig, 0.003)
        return vDSP.multiply(amp, sig)
    }

    /// Pure sine blip with a touch of octave.
    public static func blip(_ f: Float, amp: Float = 0.12, dur: Float = 0.14) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = vForce.sin(vDSP.multiply(2 * Float.pi * f, t))
        vDSP.add(sig, vDSP.multiply(0.18, vForce.sin(vDSP.multiply(4 * Float.pi * f, t))), result: &sig)
        sig = vDSP.multiply(sig, envExp(n, rate: 4.2 / dur))
        fadeIn(&sig, 0.003)
        return vDSP.multiply(amp, sig)
    }

    /// Tonal swell: root + fifth + octave rising from silence, cut 25 ms before the end.
    public static func swell(_ f: Float, amp: Float = 0.1, dur: Float = 1.5) -> [Float] {
        let n = samples(dur)
        let t = ramp(n, step: 1 / SR)
        var sig = vForce.sin(vDSP.multiply(2 * Float.pi * f, t))
        vDSP.add(sig, vDSP.multiply(0.45, vForce.sin(vDSP.multiply(2 * Float.pi * f * 1.5, t))), result: &sig)
        vDSP.add(sig, vDSP.multiply(0.35, vForce.sin(vDSP.multiply(2 * Float.pi * f * 2.003, t))), result: &sig)
        let release = samples(0.025)
        for i in 0..<n {
            let u = Float(i) / Float(n)
            let tail = min(1, Float(n - 1 - i) / Float(max(1, release)))
            sig[i] *= u * u * u * tail * amp
        }
        return sig
    }
}

// MARK: - Event mixer: ducked music bus + clean kick bus, sidechain, master

public struct Mixer {
    public let n: Int
    var L: [Float], R: [Float]                            // music bus (ducked)
    var KL: [Float], KR: [Float]                          // clean bus (kicks/booms/samples)
    var VL: [Float], VR: [Float]                          // voice bus (never ducked)
    public private(set) var kickTimes: [Double] = []
    /// (start, end) of voiceover lines — the music bus ducks under them.
    public private(set) var voiceSpans: [(Double, Double)] = []

    public init(duration: Double) {
        n = Int(duration * Double(SR))
        L = [Float](repeating: 0, count: n); R = L; KL = L; KR = L; VL = L; VR = L
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
    /// Stereo source (samples, voiceover) with a pan that balances L/R.
    public mutating func addStereo(_ l: [Float], _ r: [Float], at t: Double, gain: Float = 1,
                                   pan: Float = 0, clean: Bool = true) {
        let i = Int(t * Double(SR))
        guard i >= 0, i < n else { return }
        let m = min(l.count, n - i)
        guard m > 0 else { return }
        let gl = gain * (1 - max(0, pan)), gr = gain * (1 + min(0, pan))
        if clean {
            Self.mixInto(&KL, l, at: i, count: m, gain: gl)
            Self.mixInto(&KR, r, at: i, count: m, gain: gr)
        } else {
            Self.mixInto(&L, l, at: i, count: m, gain: gl)
            Self.mixInto(&R, r, at: i, count: m, gain: gr)
        }
    }
    /// Voiceover onto its own bus. While it speaks, the music bus ducks ~6 dB and the
    /// clean bus (kicks, booms, samples) ~4.5 dB, so hits can't bury the line.
    public mutating func addVoice(_ l: [Float], _ r: [Float], at t: Double, gain: Float = 1, pan: Float = 0) {
        let i = Int(t * Double(SR))
        guard i >= 0, i < n else { return }
        let m = min(l.count, n - i)
        guard m > 0 else { return }
        Self.mixInto(&VL, l, at: i, count: m, gain: gain * (1 - max(0, pan)))
        Self.mixInto(&VR, r, at: i, count: m, gain: gain * (1 + min(0, pan)))
        voiceSpans.append((t, t + Double(l.count) / Double(SR)))
    }
    /// Kick onto the clean bus; its onset also drives the sidechain pump.
    public mutating func addKick(_ sig: [Float], at t: Double, pan: Float = 0) {
        add(sig, at: t, pan: pan, clean: true)
        kickTimes.append(t)
    }

    /// duck → sum buses → tanh(×1.15) → fade-out → normalize to `peak`.
    public func master(fadeOut: Double = 1.2, peak: Float = 0.92, normalize: Bool = true) -> (left: [Float], right: [Float]) {
        var duck = [Float](repeating: 1, count: n)
        let dn = samples(0.42)
        let curve = (0..<dn).map { 1 - 0.5 * Foundation.exp(-Float($0) / SR / 0.11) }
        for t in kickTimes {
            let i0 = Int(t * Double(SR))
            for j in 0..<max(0, min(dn, n - i0)) { duck[i0 + j] = min(duck[i0 + j], curve[j]) }
        }
        let vAttack = Double(SR) * 0.08, vRelease = Double(SR) * 0.3
        var voiceDuck = [Float](repeating: 1, count: n)
        for (a, b) in voiceSpans {
            let s0 = max(0, Int(a * Double(SR) - vAttack)), e0 = min(n, Int(b * Double(SR) + vRelease))
            guard s0 < e0 else { continue }
            let a0 = Double(a) * Double(SR), b0 = Double(b) * Double(SR)
            for j in s0..<e0 {
                let x = Double(j)
                let ramp = x < a0 ? 1 - (a0 - x) / vAttack : (x > b0 ? 1 - (x - b0) / vRelease : 1)
                let r = Float(max(0, min(1, ramp)))
                duck[j] = min(duck[j], 1 - 0.5 * r)                 // music: −6 dB
                voiceDuck[j] = min(voiceDuck[j], 1 - 0.4 * r)       // clean: −4.5 dB
            }
        }
        func renderBus(_ music: [Float], _ clean: [Float], _ voice: [Float]) -> [Float] {
            var ch = vDSP.multiply(music, duck)
            vDSP.add(ch, vDSP.multiply(clean, voiceDuck), result: &ch)
            vDSP.add(ch, voice, result: &ch)
            return vForce.tanh(vDSP.multiply(1.15, ch))   // soft-clip master
        }
        var left = renderBus(L, KL, VL), right = renderBus(R, KR, VR)
        let fn = min(n, samples(Float(fadeOut)))
        for j in 0..<fn {                                  // linear fade to silence
            let g = Float(fn - 1 - j) / Float(max(1, fn - 1))
            left[n - fn + j] *= g; right[n - fn + j] *= g
        }
        let m = max(vDSP.maximumMagnitude(left), vDSP.maximumMagnitude(right))
        if normalize, m > 0 {
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