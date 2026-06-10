import Foundation

/// Immutable result of offline audio analysis. Pure value type: every accessor
/// is a deterministic function of `t`, so scenes that read it remain pure.
public struct AudioTrack: Sendable {
    public enum Band: String, CaseIterable, Sendable {
        case bass   // 20–250 Hz
        case mid    // 250–4000 Hz
        case high   // 4000 Hz–Nyquist

        var hzRange: ClosedRange<Double> {
            switch self {
            case .bass: return 20...250
            case .mid:  return 250...4000
            case .high: return 4000...22_050   // upper bound clamped to Nyquist at analysis time
            }
        }
    }

    /// Envelope sample rate — matches the render fps so frame f maps to index f.
    public let fps: Int
    public let duration: Double
    let rmsEnv: [Float]                 // 0…1, one entry per frame
    let bandEnvs: [Band: [Float]]       // 0…1, one entry per frame

    /// Empty track for scenes rendered without `--audio`. All queries return 0.
    public static let silent = AudioTrack(fps: 60, duration: 0, rmsEnv: [], bandEnvs: [:])

    public var isSilent: Bool { rmsEnv.isEmpty }

    /// Overall loudness (smoothed, normalized RMS) at time `t` seconds. 0…1.
    public func level(at t: Double) -> Double { sample(rmsEnv, at: t) }

    /// Energy of a frequency band at time `t` seconds. 0…1.
    public func band(_ b: Band, at t: Double) -> Double { sample(bandEnvs[b] ?? [], at: t) }

    /// Linear interpolation between per-frame samples; clamps at both ends.
    private func sample(_ env: [Float], at t: Double) -> Double {
        guard env.count > 1 else { return env.first.map(Double.init) ?? 0 }
        let x = min(max(0, t * Double(fps)), Double(env.count - 1))
        let i = Int(x)
        guard i < env.count - 1 else { return Double(env[env.count - 1]) }
        let frac = x - Double(i)
        return Double(env[i]) * (1 - frac) + Double(env[i + 1]) * frac
    }
}
