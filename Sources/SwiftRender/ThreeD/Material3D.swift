import SwiftUI

/// The contents of a material slot: a flat color, an image file, a CGImage, or any
/// SwiftUI view rendered at the current frame.
public enum Texture3D {
    case color(Color)
    /// An image file, resolved through ``AssetPaths`` and cached.
    case image(String)
    case cgImage(CGImage)
    /// A SwiftUI view rendered to a `width × height` point bitmap at `scale` every frame.
    /// The view is a pure function of whatever `t` it captured — your app's screens on a device.
    case swiftUI(width: Double, height: Double, scale: Double, content: AnyView)
    /// A plain number (metalness, roughness, …).
    case value(Double)

    /// A SwiftUI view as a texture. Size it like the surface it covers (e.g. 390×844 for a phone).
    public static func view<V: View>(width: Double, height: Double, scale: Double = 2,
                                     @ViewBuilder content: () -> V) -> Texture3D {
        .swiftUI(width: width, height: height, scale: scale, content: AnyView(content()))
    }
}

/// How a material responds to light.
public enum Lighting3DModel: Hashable {
    /// Physically based: base color + metalness + roughness (the default).
    case physical
    /// Unlit: shows its base color (and emission) exactly — titles, UI, backdrops.
    case constant
    /// Invisible except for the shadows it receives — composite onto anything.
    case shadowOnly
    case lambert, blinn
}

/// A physically based material.
///
///     .plastic(.orange)                                  // base color + roughness
///     .metal(Color(white: 0.8), roughness: 0.25)         // brushed aluminium
///     .glass(tint: .white)                               // clear-coated, transparent
///     Material3D(base: .image("tex/wood.jpg"), roughness: 0.6, normal: .image("tex/wood_n.png"))
///     .screen(Texture3D.view(width: 390, height: 844) { MyAppScreen(t: t) })
public struct Material3D {
    /// Base (albedo) color or texture.
    public var base: Texture3D
    /// Metalness, 0 (dielectric) to 1 (metal), as a value or texture.
    public var metalness: Texture3D
    /// Surface roughness, 0 (mirror) to 1 (fully diffuse), as a value or texture; very low values are clamped.
    public var roughness: Texture3D
    /// Self-illumination color or texture (nil = none).
    public var emission: Texture3D?
    /// Multiplies the emission (above 1 blooms when the camera's bloom is on).
    public var emissionIntensity: Double
    /// Normal map (nil = none).
    public var normal: Texture3D?
    /// Strength of the normal map.
    public var normalIntensity: Double
    /// Ambient occlusion map (nil = none).
    public var ambientOcclusion: Texture3D?
    /// 0…1 extra clear lacquer layer (car paint, glass screens).
    public var clearcoat: Double
    /// Roughness of the clear coat layer (clamped to a small minimum).
    public var clearcoatRoughness: Double
    /// 1 = opaque.
    public var opacity: Double
    /// Renders both faces of each polygon (for thin or transparent surfaces).
    public var doubleSided: Bool
    /// Lighting model used to shade the material.
    public var model: Lighting3DModel
    /// Repeat count for image textures (u, v).
    public var tiling: SIMD2<Double>

    /// Creates a material; `metalness` and `roughness` are scalar values here.
    public init(base: Texture3D = .color(.white), metalness: Double = 0, roughness: Double = 0.5,
                emission: Texture3D? = nil, emissionIntensity: Double = 1,
                normal: Texture3D? = nil, normalIntensity: Double = 1, ambientOcclusion: Texture3D? = nil,
                clearcoat: Double = 0, clearcoatRoughness: Double = 0.05, opacity: Double = 1,
                doubleSided: Bool = false, model: Lighting3DModel = .physical, tiling: SIMD2<Double> = [1, 1]) {
        self.base = base; self.metalness = .value(metalness); self.roughness = .value(roughness)
        self.emission = emission; self.emissionIntensity = emissionIntensity
        self.normal = normal; self.normalIntensity = normalIntensity; self.ambientOcclusion = ambientOcclusion
        self.clearcoat = clearcoat; self.clearcoatRoughness = clearcoatRoughness
        self.opacity = opacity; self.doubleSided = doubleSided; self.model = model; self.tiling = tiling
    }

    /// Dielectric (plastic, paint, ceramic).
    public static func plastic(_ color: Color, roughness: Double = 0.4, clearcoat: Double = 0) -> Material3D {
        Material3D(base: .color(color), roughness: roughness, clearcoat: clearcoat)
    }
    /// Very rough dielectric — paper, plaster, a studio floor.
    public static func matte(_ color: Color) -> Material3D { Material3D(base: .color(color), roughness: 0.92) }
    /// Metal: the color is the reflectance (aluminium ≈ 0.9 white, gold ≈ (1, 0.78, 0.34)).
    public static func metal(_ color: Color = Color(white: 0.9), roughness: Double = 0.25) -> Material3D {
        Material3D(base: .color(color), metalness: 1, roughness: roughness)
    }
    /// Transparent clear-coated glass (no refraction — SceneKit rasterises).
    public static func glass(tint: Color = .white, opacity: Double = 0.18) -> Material3D {
        Material3D(base: .color(tint), roughness: 0.02, clearcoat: 1, clearcoatRoughness: 0.01,
                   opacity: opacity, doubleSided: true)
    }
    /// Self-lit color, bright enough to bloom above `intensity` 1.
    public static func emissive(_ color: Color, intensity: Double = 1) -> Material3D {
        Material3D(base: .color(.black), roughness: 0.6, emission: .color(color), emissionIntensity: intensity)
    }
    /// Unlit: the texture exactly as authored (titles, backdrops, UI cards).
    public static func unlit(_ texture: Texture3D) -> Material3D {
        Material3D(base: texture, model: .constant)
    }
    /// A display: the texture glows on its own (unaffected by scene lights) under a glossy
    /// clear coat that still catches the studio's reflections, like real cover glass.
    public static func screen(_ texture: Texture3D, brightness: Double = 1, gloss: Double = 0.6) -> Material3D {
        Material3D(base: .color(.black), roughness: 0.25, emission: texture, emissionIntensity: brightness,
                   clearcoat: gloss, clearcoatRoughness: 0.02)
    }
    /// Invisible except for received shadows (`opacity` darkens them).
    public static func shadowCatcher(opacity: Double = 1) -> Material3D {
        Material3D(base: .color(.white), opacity: opacity, model: .shadowOnly)
    }
}
