import Foundation

/// Stateless, closed-form damped spring. Position at any time `t` is computed
/// analytically (no per-frame integration), so scrubbing or re-rendering any
/// frame yields identical results.
public struct Spring: Equatable, Sendable {
    public var stiffness: Double   // k, with mass normalized to 1
    public var damping: Double     // c

    public init(stiffness: Double = 170, damping: Double = 26) {
        self.stiffness = max(stiffness, 1e-9)
        self.damping = max(damping, 0)
    }

    /// SwiftUI-style parameters. `response`: undamped period in seconds.
    /// `dampingFraction`: <1 bouncy, 1 critical, >1 overdamped.
    public init(response: Double, dampingFraction: Double) {
        let w0 = 2 * .pi / max(response, 1e-9)
        self.init(stiffness: w0 * w0, damping: 2 * max(dampingFraction, 0) * w0)
    }

    /// Analytic position and velocity at time `t` (seconds).
    public func evaluate(at t: Double, from: Double, to: Double,
                         initialVelocity v0: Double = 0) -> (value: Double, velocity: Double) {
        guard t > 0 else { return (from, v0) }
        let w0 = sqrt(stiffness), zeta = damping / (2 * w0), y0 = from - to
        let y: Double, dy: Double
        if abs(zeta - 1) < 1e-8 {                                  // critically damped
            let c2 = v0 + w0 * y0, e = exp(-w0 * t)
            y  = e * (y0 + c2 * t)
            dy = e * (c2 - w0 * (y0 + c2 * t))
        } else if zeta < 1 {                                       // underdamped
            let wd = w0 * (1 - zeta * zeta).squareRoot(), a = zeta * w0
            let b = (v0 + a * y0) / wd
            let e = exp(-a * t), c = cos(wd * t), s = sin(wd * t)
            y  = e * (y0 * c + b * s)
            dy = e * ((b * wd - a * y0) * c - (y0 * wd + a * b) * s)
        } else {                                                   // overdamped
            let q = w0 * (zeta * zeta - 1).squareRoot()
            let r1 = -zeta * w0 + q, r2 = -zeta * w0 - q
            let c1 = (v0 - r2 * y0) / (r1 - r2), c2 = y0 - c1
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            y  = c1 * e1 + c2 * e2
            dy = c1 * r1 * e1 + c2 * r2 * e2
        }
        return (to + y, dy)
    }

    public func value(at t: Double, from: Double, to: Double, initialVelocity v0: Double = 0) -> Double {
        evaluate(at: t, from: from, to: to, initialVelocity: v0).value
    }

    /// Time after which the decay envelope is within `epsilon` (relative) of the target.
    public func settlingDuration(epsilon: Double = 1e-3) -> Double {
        let w0 = sqrt(stiffness), zeta = damping / (2 * w0)
        let rate = zeta < 1 ? zeta * w0 : w0 * (zeta - (zeta * zeta - 1).squareRoot())
        return -log(epsilon) / max(rate, 1e-9)
    }
}

/// CSS-style cubic bezier timing curve through (0,0), p1, p2, (1,1).
/// x(u) is inverted with fixed-count Newton iterations (deterministic).
public struct CubicBezier: Equatable, Sendable {
    private let ax, bx, cx, ay, by, cy: Double
    public init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        let x1 = min(1, max(0, p1x)), x2 = min(1, max(0, p2x))    // keeps x(u) monotonic
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }
    public func callAsFunction(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        var u = p
        for _ in 0..<8 {                                          // Newton on x(u) = p
            let f = ((ax * u + bx) * u + cx) * u - p
            let d = (3 * ax * u + 2 * bx) * u + cx
            if abs(d) < 1e-7 { break }
            u = min(1, max(0, u - f / d))
        }
        return ((ay * u + by) * u + cy) * u
    }
}

public extension Ease {
    /// Convenience: closed-form spring sampled at absolute time `t` (seconds since clip start).
    static func spring(_ t: Double, from: Double, to: Double,
                       response: Double = 0.5, dampingFraction: Double = 0.825,
                       initialVelocity: Double = 0) -> Double {
        Spring(response: response, dampingFraction: dampingFraction)
            .value(at: t, from: from, to: to, initialVelocity: initialVelocity)
    }

    static func spring(_ t: Double, from: Double, to: Double,
                       stiffness: Double, damping: Double, initialVelocity: Double = 0) -> Double {
        Spring(stiffness: stiffness, damping: damping)
            .value(at: t, from: from, to: to, initialVelocity: initialVelocity)
    }

    /// Ease-out with overshoot; `overshoot` 1.70158 ≈ 10% past the target.
    static func easeOutBack(_ x: Double, overshoot s: Double = 1.70158) -> Double {
        let p = min(1, max(0, x)) - 1
        return 1 + p * p * ((s + 1) * p + s)
    }

    /// Ease-out elastic (decaying sinusoid into the target).
    static func elastic(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        if p == 0 || p == 1 { return p }
        return pow(2, -10 * p) * sin((p * 10 - 0.75) * (2 * .pi / 3)) + 1
    }

    /// Ease-out bounce (four parabolic arcs).
    static func bounce(_ x: Double) -> Double {
        var p = min(1, max(0, x))
        let n = 7.5625, d = 2.75
        if p < 1 / d { return n * p * p }
        if p < 2 / d { p -= 1.5 / d; return n * p * p + 0.75 }
        if p < 2.5 / d { p -= 2.25 / d; return n * p * p + 0.9375 }
        p -= 2.625 / d
        return n * p * p + 0.984375
    }

    /// Ease-out exponential.
    static func expo(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        return p >= 1 ? 1 : 1 - pow(2, -10 * p)
    }

    static func cubicBezier(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) -> CubicBezier {
        CubicBezier(p1x, p1y, p2x, p2y)
    }
}
