import SwiftUI

/// Shadow settings for a light. Soft shadows come from `softness` (blur radius in
/// shadow-map texels) and `samples` (more = smoother penumbra, slower).
public struct Shadow3D {
    /// Shadow color (its alpha sets how dark the shadow is).
    public var color: Color
    /// Blur radius of the shadow edge.
    public var softness: Double
    /// Shadow samples per pixel; more gives a smoother penumbra at higher cost.
    public var samples: Int
    /// Shadow map resolution (square).
    public var mapSize: Int
    /// Directional lights only: half-height, in scene units, of the area that can
    /// receive shadows. Keep it just larger than the subject for crisp maps.
    public var extent: Double
    /// Depth bias that offsets the shadow map to avoid self-shadowing artifacts.
    public var bias: Double

    /// Creates shadow settings; the defaults give a soft shadow with a 4096-pixel map.
    public init(color: Color = Color.black.opacity(0.6), softness: Double = 8, samples: Int = 24,
                mapSize: Int = 4096, extent: Double = 1, bias: Double = 1) {
        self.color = color; self.softness = softness; self.samples = samples
        self.mapSize = mapSize; self.extent = extent; self.bias = bias
    }

    /// A broad, soft product-shot shadow.
    public static func soft(extent: Double = 1, opacity: Double = 0.55) -> Shadow3D {
        Shadow3D(color: Color.black.opacity(opacity), softness: 14, samples: 32, extent: extent)
    }
    /// A crisp, single-sample shadow with almost no edge blur.
    public static func hard(extent: Double = 1, opacity: Double = 0.8) -> Shadow3D {
        Shadow3D(color: Color.black.opacity(opacity), softness: 1, samples: 1, extent: extent)
    }
}

/// A light source. Build lights with the static functions, which return positioned
/// ``Node3D``s (lights shine along their −Z axis, so they `look(at:)` the target):
///
///     Light3D.directional(intensity: 1200, from: [2, 4, 3], shadow: .soft(extent: 0.4))
///     Light3D.spot(intensity: 900, from: [-1, 2, 1], at: [0, 0.1, 0], angle: 40)
///     Light3D.area(intensity: 600, width: 1.5, height: 0.6, from: [0, 1.5, 1.5])
///     Light3D.omni(intensity: 300, at: [0, 1, 0], color: .orange)
///
/// Intensities are SceneKit lumens (1000 ≈ a neutral key light). Image-based lighting
/// from ``Environment3D`` adds on top of these.
public struct Light3D {
    /// The type of light. Spot cone angles are in degrees; area sizes are in scene units.
    public enum Kind: Hashable {
        case directional
        case spot(inner: Double, outer: Double)
        case omni
        case area(width: Double, height: Double)
        case ambient
    }

    /// The type of light.
    public var kind: Kind
    /// Light color (multiplied with `temperature` when set).
    public var color: Color
    /// Brightness in SceneKit lumens (1000 is roughly a neutral key light).
    public var intensity: Double
    /// Optional color temperature in Kelvin (6500 = neutral), multiplied with `color`.
    public var temperature: Double?
    /// Shadow settings (nil = no shadow). Only directional and spot lights cast shadows.
    public var shadow: Shadow3D?
    /// Omni/spot: distance where light starts and finishes fading (nil = physical falloff).
    public var attenuation: ClosedRange<Double>?

    /// Creates a light description. The static builders are usually easier, since they also position the light.
    public init(_ kind: Kind, color: Color = .white, intensity: Double = 1000, temperature: Double? = nil,
                shadow: Shadow3D? = nil, attenuation: ClosedRange<Double>? = nil) {
        self.kind = kind; self.color = color; self.intensity = intensity
        self.temperature = temperature; self.shadow = shadow; self.attenuation = attenuation
    }

    /// Parallel light from the direction of `from` toward `at` (sun, key light).
    public static func directional(intensity: Double = 1000, color: Color = .white, temperature: Double? = nil,
                                   from: Vec3, at: Vec3 = .zero, shadow: Shadow3D? = nil) -> Node3D {
        Node3D(.light(Light3D(.directional, color: color, intensity: intensity, temperature: temperature,
                              shadow: shadow))).position(from).look(at: at)
    }

    /// A cone of light; `angle` is the full outer cone angle in degrees.
    public static func spot(intensity: Double = 1000, color: Color = .white, temperature: Double? = nil,
                            from: Vec3, at: Vec3 = .zero, angle: Double = 45, softEdge: Double = 0.3,
                            shadow: Shadow3D? = nil) -> Node3D {
        Node3D(.light(Light3D(.spot(inner: angle * (1 - softEdge), outer: angle), color: color, intensity: intensity,
                              temperature: temperature, shadow: shadow))).position(from).look(at: at)
    }

    /// A point light radiating in every direction.
    public static func omni(intensity: Double = 1000, color: Color = .white, temperature: Double? = nil,
                            at: Vec3, attenuation: ClosedRange<Double>? = nil) -> Node3D {
        Node3D(.light(Light3D(.omni, color: color, intensity: intensity, temperature: temperature,
                              attenuation: attenuation))).position(at)
    }

    /// A rectangular soft box. SceneKit area lights do not cast shadows; pair one with a
    /// shadow-casting directional key.
    public static func area(intensity: Double = 1000, color: Color = .white, temperature: Double? = nil,
                            width: Double = 1, height: Double = 1, from: Vec3, at: Vec3 = .zero) -> Node3D {
        Node3D(.light(Light3D(.area(width: width, height: height), color: color, intensity: intensity,
                              temperature: temperature))).position(from).look(at: at)
    }

    /// Flat fill light from everywhere (use sparingly; prefer ``Environment3D``).
    public static func ambient(intensity: Double = 100, color: Color = .white) -> Node3D {
        Node3D(.light(Light3D(.ambient, color: color, intensity: intensity)))
    }

    /// A classic three-point product rig around `target`: a shadow-casting key from the
    /// front-left above, a soft fill from the right, and a rim from behind.
    /// `size` is roughly the subject's size (sets distances and the shadow extent).
    public static func studioRig(target: Vec3 = .zero, size: Double = 0.3, key: Double = 1100,
                                 fill: Double = 350, rim: Double = 900, warmth: Double = 5600,
                                 shadow: Shadow3D? = nil) -> [Node3D] {
        let d = size * 6
        return [
            directional(intensity: key, temperature: warmth, from: target + [-0.55 * d, 1.1 * d, 0.75 * d], at: target,
                        shadow: shadow ?? .soft(extent: size * 1.6)),
            area(intensity: fill, temperature: 6500, width: size * 3, height: size * 3,
                 from: target + [0.9 * d, 0.35 * d, 0.6 * d], at: target),
            spot(intensity: rim, temperature: 7200, from: target + [0.25 * d, 0.8 * d, -1.0 * d], at: target, angle: 50),
        ]
    }
}
