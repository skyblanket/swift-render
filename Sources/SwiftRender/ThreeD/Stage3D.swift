import SwiftUI

/// Image-based lighting: what metals and glossy surfaces reflect, and soft fill everywhere.
public struct Environment3D: Equatable {
    /// Where the environment image comes from: none, the procedural studio, or an image file.
    public enum Source: Equatable {
        case none
        case studio
        case file(String)
    }

    /// Where the environment image comes from.
    public var source: Source
    /// Multiplier for the image-based light (and for an environment background's brightness).
    public var intensity: Double
    /// Spin about Y in degrees (moves the highlights around the subject).
    public var rotation: Double

    /// Creates an environment from a source, an intensity and a Y rotation in degrees.
    public init(source: Source, intensity: Double = 1, rotation: Double = 0) {
        self.source = source; self.intensity = intensity; self.rotation = rotation
    }

    /// No image-based light (only explicit lights).
    public static var none: Environment3D { Environment3D(source: .none) }
    /// A procedural photo studio: dark walls, a big overhead soft box, two tall strip
    /// boxes and a low bounce card. Generated once per process as a float HDR image, so it
    /// costs nothing per frame.
    public static var studio: Environment3D { Environment3D(source: .studio) }
    /// The procedural studio with a custom intensity and Y rotation in degrees.
    public static func studio(intensity: Double = 1, rotation: Double = 0) -> Environment3D {
        Environment3D(source: .studio, intensity: intensity, rotation: rotation)
    }
    /// An equirectangular image file — `.hdr`, `.exr`, or any image — through ``AssetPaths``.
    public static func file(_ path: String, intensity: Double = 1, rotation: Double = 0) -> Environment3D {
        Environment3D(source: .file(path), intensity: intensity, rotation: rotation)
    }
}

/// What shows behind the objects.
public enum Background3D {
    case color(Color)
    /// A SwiftUI view rendered (at the frame's pixel size) as the backdrop *inside* the 3D
    /// render, so depth of field, bloom and shadow-catcher floors treat it as real background.
    /// Prefer this over `.transparent` + a SwiftUI layer underneath when the camera uses
    /// depth of field.
    case swiftUI(AnyView)
    /// Alpha 0 wherever nothing is drawn, so the 3D layer composites over any SwiftUI
    /// content beneath it (pair with ``Material3D/shadowCatcher(opacity:)`` floors).
    case transparent
    /// The environment image itself (a visible sky / studio).
    case environment

    /// A SwiftUI backdrop rendered inside the 3D frame (see ``swiftUI(_:)``).
    public static func view<V: View>(@ViewBuilder _ content: () -> V) -> Background3D {
        .swiftUI(AnyView(content()))
    }
}

/// Distance fog (linear from `start` to `end`, shaped by `exponent`).
public struct Fog3D: Equatable {
    /// Fog color.
    public var color: Color
    /// Distance from the camera where fog begins, in scene units.
    public var start: Double
    /// Distance where fog reaches full strength, in scene units.
    public var end: Double
    /// Shapes the fog ramp between `start` and `end` (1 = linear).
    public var exponent: Double
    /// Creates fog that ramps from `start` to `end`.
    public init(color: Color, start: Double, end: Double, exponent: Double = 1) {
        self.color = color; self.start = start; self.end = end; self.exponent = exponent
    }
}

/// Bloom on bright pixels (emission above 1, specular hot spots).
public struct Bloom3D: Equatable {
    /// Strength of the bloom.
    public var intensity: Double
    /// Luminance above which pixels bloom (0…1 after exposure).
    public var threshold: Double
    /// Blur radius of the bloom.
    public var radius: Double
    /// Creates bloom settings.
    public init(intensity: Double = 0.6, threshold: Double = 0.85, radius: Double = 12) {
        self.intensity = intensity; self.threshold = threshold; self.radius = radius
    }
}

/// Camera-side image processing. HDR (on by default) renders in floating point and
/// tone maps with a filmic curve; exposure adaptation and motion blur, which depend on
/// previous frames, are always off.
public struct Effects3D: Equatable {
    /// Renders in floating point and tone maps with a filmic curve.
    public var hdr: Bool
    /// Exposure offset in stops.
    public var exposure: Double
    /// Bloom settings (nil = off).
    public var bloom: Bloom3D?
    /// Screen-space ambient occlusion strength (0 = off).
    public var ambientOcclusion: Double
    /// Sampling radius of the ambient occlusion, in scene units.
    public var ambientOcclusionRadius: Double
    /// Darkens the frame edges (0 = off).
    public var vignette: Double
    /// Color saturation (1 = unchanged, 0 = grayscale).
    public var saturation: Double
    /// Contrast adjustment (0 = unchanged).
    public var contrast: Double

    /// Creates camera effects; the defaults are HDR with no bloom, occlusion or vignette.
    public init(hdr: Bool = true, exposure: Double = 0, bloom: Bloom3D? = nil, ambientOcclusion: Double = 0,
                ambientOcclusionRadius: Double = 0.05, vignette: Double = 0, saturation: Double = 1,
                contrast: Double = 0) {
        self.hdr = hdr; self.exposure = exposure; self.bloom = bloom
        self.ambientOcclusion = ambientOcclusion; self.ambientOcclusionRadius = ambientOcclusionRadius
        self.vignette = vignette; self.saturation = saturation; self.contrast = contrast
    }

    /// HDR only: no bloom, occlusion, vignette or grading.
    public static var standard: Effects3D { Effects3D() }
    /// HDR + gentle bloom + a touch of contact occlusion — the product-shot default.
    public static var cinematic: Effects3D {
        Effects3D(bloom: Bloom3D(intensity: 0.35, threshold: 0.9, radius: 10), ambientOcclusion: 0.6)
    }
}

/// Multisampling for the 3D layer (SceneKit's `SCNAntialiasingMode`).
public enum Antialiasing3D: Equatable {
    case none, x2, x4
}
