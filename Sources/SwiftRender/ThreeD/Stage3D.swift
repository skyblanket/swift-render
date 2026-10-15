import SwiftUI

/// Image-based lighting: what metals and glossy surfaces reflect, and soft fill everywhere.
public struct Environment3D: Equatable {
    public enum Source: Equatable {
        case none
        case studio
        case file(String)
    }

    public var source: Source
    public var intensity: Double
    /// Spin about Y in degrees (moves the highlights around the subject).
    public var rotation: Double

    public init(source: Source, intensity: Double = 1, rotation: Double = 0) {
        self.source = source; self.intensity = intensity; self.rotation = rotation
    }

    /// No image-based light (only explicit lights).
    public static var none: Environment3D { Environment3D(source: .none) }
    /// A procedural photo studio: dark walls, a big overhead soft box, two tall strip
    /// boxes and a low bounce card. Generated once per process as a float HDR image, so it
    /// costs nothing per frame.
    public static var studio: Environment3D { Environment3D(source: .studio) }
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
    public var color: Color
    public var start: Double
    public var end: Double
    public var exponent: Double
    public init(color: Color, start: Double, end: Double, exponent: Double = 1) {
        self.color = color; self.start = start; self.end = end; self.exponent = exponent
    }
}

/// Bloom on bright pixels (emission above 1, specular hot spots).
public struct Bloom3D: Equatable {
    public var intensity: Double
    /// Luminance above which pixels bloom (0…1 after exposure).
    public var threshold: Double
    public var radius: Double
    public init(intensity: Double = 0.6, threshold: Double = 0.85, radius: Double = 12) {
        self.intensity = intensity; self.threshold = threshold; self.radius = radius
    }
}

/// Camera-side image processing. HDR (on by default) renders in floating point and
/// tone maps with a filmic curve; exposure adaptation and motion blur, which depend on
/// previous frames, are always off.
public struct Effects3D: Equatable {
    public var hdr: Bool
    /// Exposure offset in stops.
    public var exposure: Double
    public var bloom: Bloom3D?
    /// Screen-space ambient occlusion strength (0 = off).
    public var ambientOcclusion: Double
    public var ambientOcclusionRadius: Double
    /// Darkens the frame edges (0 = off).
    public var vignette: Double
    public var saturation: Double
    public var contrast: Double

    public init(hdr: Bool = true, exposure: Double = 0, bloom: Bloom3D? = nil, ambientOcclusion: Double = 0,
                ambientOcclusionRadius: Double = 0.05, vignette: Double = 0, saturation: Double = 1,
                contrast: Double = 0) {
        self.hdr = hdr; self.exposure = exposure; self.bloom = bloom
        self.ambientOcclusion = ambientOcclusion; self.ambientOcclusionRadius = ambientOcclusionRadius
        self.vignette = vignette; self.saturation = saturation; self.contrast = contrast
    }

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
