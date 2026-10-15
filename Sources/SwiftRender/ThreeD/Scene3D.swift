import SwiftUI

/// True 3D inside any scene: a SceneKit scene rendered offscreen at the frame's real pixel
/// size and returned as an image, so it composites with SwiftUI, shaders and `PostFX`
/// like any other view.
///
///     Scene3D(camera: .orbit(distance: 0.6, azimuth: Motion3D.turntable(t, degreesPerSecond: 12), elevation: 8)
///                 .focused(on: [0, 0.08, 0], fStop: 2.2),
///             environment: .studio, background: .color(.black), effects: .cinematic) {
///         Slab3D(width: 0.075, height: 0.155, depth: 0.008, cornerRadius: 0.011,
///                screen: .screen(.view(width: 390, height: 844) { HomeScreen(t: t) }))
///             .material(.metal(Color(white: 0.2), roughness: 0.3))
///             .position(0, 0.08, 0)
///         Floor3D(material: .matte(Color(white: 0.04)))
///         Light3D.studioRig(target: [0, 0.08, 0], size: 0.16)
///     }
///
/// **Determinism.** The description is rebuilt from `t` every frame and the engine sets
/// every property of every node from it, so nothing carries over from the previous frame.
/// SceneKit's own clock is never used: the scene is paused, physics is stopped, embedded
/// model animations are removed, jittering and temporal antialiasing are off, and the
/// camera's exposure adaptation and motion blur (both history-dependent) are disabled.
///
/// **Caching.** The SceneKit scene, its `SCNRenderer`, the Metal device, loaded models,
/// meshes and environment maps are kept across frames, keyed by `id` (default: the call
/// site). Give each simultaneously visible `Scene3D` from the same call site its own `id`.
public struct Scene3D: View {
    public var camera: Camera3D
    public var environment: Environment3D
    public var background: Background3D
    public var fog: Fog3D?
    public var effects: Effects3D
    public var antialiasing: Antialiasing3D
    public var id: String
    public var nodes: [Node3D]

    @Environment(\.displayScale) private var displayScale

    public init(camera: Camera3D, environment: Environment3D = .studio, background: Background3D = .color(.black),
                fog: Fog3D? = nil, effects: Effects3D = .standard, antialiasing: Antialiasing3D = .x4,
                id: String? = nil, fileID: String = #fileID, line: Int = #line,
                @Scene3DBuilder content: () -> [Node3D]) {
        self.camera = camera; self.environment = environment; self.background = background
        self.fog = fog; self.effects = effects; self.antialiasing = antialiasing
        self.id = id ?? "\(fileID):\(line)"
        self.nodes = content()
    }

    public var body: some View {
        GeometryReader { geo in
            let scale = max(0.01, displayScale)
            if let cg = image(size: geo.size, scale: scale) {
                Image(decorative: cg, scale: scale)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                Color.clear
            }
        }
    }

    /// Render this scene to a `CGImage` of `size × scale` pixels (premultiplied sRGB).
    /// This is what `body` draws; call it directly for tests or custom compositing.
    @MainActor
    public func image(size: CGSize, scale: CGFloat = 1) -> CGImage? {
        let px = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        return Engine3D.shared.render(self, pixelSize: px, layoutSize: size, scale: scale)
    }
}

public extension Scene3D {
    /// Milliseconds the last `Scene3D` render took on this thread (reconcile + textures + GPU + readback).
    @MainActor static var lastRenderMilliseconds: Double { Engine3D.shared.lastMilliseconds }

    /// Drop every cached scene, renderer, model and environment map (tests; freeing memory).
    @MainActor static func purgeCaches() { Engine3D.shared.purge() }
}
