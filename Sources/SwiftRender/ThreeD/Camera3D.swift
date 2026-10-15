import Foundation
import simd

/// Depth of field. SceneKit models a real lens: blur grows with aperture
/// (lower `fStop`) and with distance from the focus plane.
public struct DepthOfField3D: Equatable {
    /// Distance from the camera to the plane in focus, in scene units.
    public var focusDistance: Double
    /// Aperture as an f-number; lower values give a shallower focus range and more blur.
    public var fStop: Double
    /// Aperture blades (bokeh shape); 0 = round.
    public var blades: Int

    /// Creates depth-of-field settings focused `focusDistance` scene units from the camera.
    public init(focusDistance: Double, fStop: Double = 2.8, blades: Int = 0) {
        self.focusDistance = focusDistance; self.fStop = fStop; self.blades = blades
    }
}

/// A camera: where it is, what it looks at, the lens. A plain value — interpolate it,
/// spring it, compute it from `t`.
///
///     Camera3D(position: [0, 0.2, 1.2], target: [0, 0.1, 0], fov: 30)
///         .focused(on: [0, 0.1, 0], fStop: 2)
///     Camera3D.orbit(target: .zero, distance: 1.4, azimuth: Motion3D.turntable(t, degreesPerSecond: 10), elevation: 12)
///     Camera3D.dolly(t, from: wide, to: close, start: 1, end: 5)        // eased push-in
public struct Camera3D: Equatable {
    /// Camera position in world space.
    public var position: Vec3
    /// World point the camera looks at.
    public var target: Vec3
    /// Up direction used to orient the camera.
    public var up: Vec3
    /// Vertical field of view in degrees.
    public var fov: Double
    /// Roll about the view axis in degrees.
    public var roll: Double
    /// Near clipping distance in scene units.
    public var near: Double
    /// Far clipping distance in scene units.
    public var far: Double
    /// Depth of field settings (nil = everything in focus).
    public var depthOfField: DepthOfField3D?
    /// Orthographic projection: half the view height in scene units (nil = perspective).
    public var orthographicScale: Double?

    /// Creates a camera at `position` looking at `target`; perspective unless `orthographicScale` is set.
    public init(position: Vec3 = [0, 0, 3], target: Vec3 = .zero, up: Vec3 = [0, 1, 0], fov: Double = 35,
                roll: Double = 0, near: Double = 0.01, far: Double = 200,
                depthOfField: DepthOfField3D? = nil, orthographicScale: Double? = nil) {
        self.position = position; self.target = target; self.up = up; self.fov = fov; self.roll = roll
        self.near = near; self.far = far; self.depthOfField = depthOfField; self.orthographicScale = orthographicScale
    }

    /// A camera on a sphere around `target`: `azimuth` degrees around Y (0 = on +Z,
    /// looking toward −Z), `elevation` degrees above the horizon.
    public static func orbit(target: Vec3 = .zero, distance: Double, azimuth: Double, elevation: Double = 10,
                             fov: Double = 35) -> Camera3D {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        let offset: Vec3 = [distance * cos(e) * sin(a), distance * sin(e), distance * cos(e) * cos(a)]
        return Camera3D(position: target + offset, target: target, fov: fov)
    }

    /// Focus on a world point (the focus distance tracks the camera as it moves).
    public func focused(on point: Vec3, fStop: Double = 2.8, blades: Int = 0) -> Camera3D {
        var c = self
        c.depthOfField = DepthOfField3D(focusDistance: simd_length(point - position), fStop: fStop, blades: blades)
        return c
    }

    /// Focus at a fixed distance from the camera.
    public func focused(distance: Double, fStop: Double = 2.8, blades: Int = 0) -> Camera3D {
        var c = self; c.depthOfField = DepthOfField3D(focusDistance: distance, fStop: fStop, blades: blades); return c
    }

    /// Move along the view axis: positive pushes in toward the target, negative pulls out.
    /// The focus distance follows, so a focused subject stays sharp.
    public func dollied(_ amount: Double) -> Camera3D {
        var c = self
        let dir = simd_normalize(target - position)
        c.position += dir * amount
        c.depthOfField?.focusDistance -= amount
        return c
    }

    /// Straight-line interpolation of position, target, lens and focus (`p` 0…1, unclamped
    /// so springs may overshoot).
    public static func lerp(_ a: Camera3D, _ b: Camera3D, _ p: Double) -> Camera3D {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * p }
        var c = a
        c.position = a.position + (b.position - a.position) * p
        c.target = a.target + (b.target - a.target) * p
        c.up = simd_normalize(a.up + (b.up - a.up) * p)
        c.fov = mix(a.fov, b.fov); c.roll = mix(a.roll, b.roll)
        c.near = mix(a.near, b.near); c.far = mix(a.far, b.far)
        switch (a.depthOfField, b.depthOfField) {
        case let (x?, y?):
            c.depthOfField = DepthOfField3D(focusDistance: mix(x.focusDistance, y.focusDistance),
                                            fStop: mix(x.fStop, y.fStop), blades: p < 0.5 ? x.blades : y.blades)
        case let (x?, nil): c.depthOfField = p < 1 ? x : nil
        case let (nil, y?): c.depthOfField = p > 0 ? y : nil
        default: c.depthOfField = nil
        }
        if let x = a.orthographicScale, let y = b.orthographicScale { c.orthographicScale = mix(x, y) }
        return c
    }

    /// An eased move from `from` to `to` over `start…end` seconds (default ease-in-out).
    public static func dolly(_ t: Double, from: Camera3D, to: Camera3D, start: Double, end: Double,
                             easing: (Double) -> Double = Ease.easeInOut) -> Camera3D {
        lerp(from, to, easing(Ease.clip(t, start, end)))
    }

    /// A damped-spring move from `from` to `to` released at `start` (closed form: scrub-safe).
    public static func spring(_ t: Double, from: Camera3D, to: Camera3D, start: Double,
                              response: Double = 1.2, dampingFraction: Double = 0.85) -> Camera3D {
        lerp(from, to, Ease.spring(max(0, t - start), from: 0, to: 1, response: response, dampingFraction: dampingFraction))
    }
}

/// Motion helpers that are pure functions of `t` — angles in degrees.
public enum Motion3D {
    /// A constant spin: `start + degreesPerSecond × t`.
    public static func turntable(_ t: Double, degreesPerSecond: Double = 15, start: Double = 0) -> Double {
        start + degreesPerSecond * t
    }

    /// A gentle sine sway of ±`degrees` with `period` seconds.
    public static func oscillate(_ t: Double, degrees: Double, period: Double = 4, phase: Double = 0) -> Double {
        degrees * sin(2 * .pi * (t / max(period, 1e-9)) + phase)
    }

    /// A slow float up and down by `amplitude` units (product "hover").
    public static func hover(_ t: Double, amplitude: Double = 0.01, period: Double = 5, phase: Double = 0) -> Double {
        amplitude * sin(2 * .pi * (t / max(period, 1e-9)) + phase)
    }

    /// A turntable that eases in from rest over `rampUp` seconds instead of starting at full speed.
    public static func easedTurntable(_ t: Double, degreesPerSecond: Double, rampUp: Double = 1.5,
                                      start: Double = 0) -> Double {
        guard rampUp > 0 else { return turntable(t, degreesPerSecond: degreesPerSecond, start: start) }
        // Integral of a smoothstep speed ramp: exact angle, so no jump when the ramp ends.
        let r = rampUp
        if t <= 0 { return start }
        if t >= r { return start + degreesPerSecond * (t - r / 2) }
        let x = t / r
        return start + degreesPerSecond * r * (x * x * x - 0.5 * x * x * x * x)
    }
}
