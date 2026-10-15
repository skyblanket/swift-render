import AppKit
import Metal
import SceneKit
import SwiftUI
import simd

/// Owns the Metal device, one shared `SCNRenderer` and one cached SceneKit scene per `Scene3D` id.
/// Main-actor only (SwiftUI's ImageRenderer evaluates views there).
@MainActor
final class Engine3D {
    static let shared = Engine3D()

    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let entryLimit = 8
    private(set) var lastMilliseconds: Double = 0
    private(set) var lastPixelSize: CGSize = .zero
    private var warnedNoDevice = false

    /// One renderer for every scene. SceneKit seeds some per-renderer state (sampling
    /// noise for soft shadows, SSAO, depth of field) that is stable for that renderer's
    /// lifetime but differs between instances; sharing one keeps every scene on the same
    /// seed, so pixels never depend on which scene happened to be created first.
    private lazy var renderer: SCNRenderer = {
        let r = SCNRenderer(device: device, options: nil)
        r.autoenablesDefaultLighting = false
        r.isJitteringEnabled = false
        r.isTemporalAntialiasingEnabled = false
        r.isPlaying = false
        r.loops = false
        return r
    }()

    final class Entry {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        let backdrop = SCNNode()
        let content = ManagedNode(kindKey: .group)
        var environmentKey: String?
        var environmentImage: CGImage?

        init() {
            scene.isPaused = true
            scene.physicsWorld.speed = 0
            scene.physicsWorld.gravity = SCNVector3(0, 0, 0)
            cameraNode.camera = SCNCamera()
            cameraNode.name = "swift-render.camera"
            content.name = "swift-render.content"
            scene.rootNode.addChildNode(cameraNode)
            cameraNode.addChildNode(backdrop)
            scene.rootNode.addChildNode(content)
        }
    }

    /// `SR_3D_STATS=1` prints the mean Scene3D cost every 120 renders (stderr).
    private struct Stats {
        let enabled = ProcessInfo.processInfo.environment["SR_3D_STATS"] != nil
        var total: Double = 0, count = 0
        mutating func add(_ ms: Double, pixelSize: CGSize) {
            guard enabled else { return }
            total += ms; count += 1
            if count % 120 == 0 {
                fputs(String(format: "[swift-render] Scene3D: %.1f ms/render mean over %d renders at %d×%d\n",
                             total / Double(count), count, Int(pixelSize.width), Int(pixelSize.height)), stderr)
            }
        }
    }
    private var stats = Stats()

    func purge() {
        entries = [:]; order = []
        Models3D.purge(); Textures3D.purge(); Geometries3D.purge(); EnvironmentMaps.purge()
    }

    func render(_ s: Scene3D, pixelSize: CGSize, layoutSize: CGSize, scale: CGFloat) -> CGImage? {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            stats.add(lastMilliseconds, pixelSize: pixelSize)
        }
        lastPixelSize = pixelSize
        guard device != nil else {
            if !warnedNoDevice {
                warnedNoDevice = true
                fputs("[swift-render] WARN: Scene3D needs Metal; no GPU device is available — drawing nothing\n", stderr)
            }
            return nil
        }
        let entry = self.entry(for: s.id)

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0
        applyStage(s, to: entry, layoutSize: layoutSize, scale: scale)
        applyCamera(s.camera, effects: s.effects, aspect: pixelSize.width / max(1, pixelSize.height), to: entry.cameraNode)
        applyBackdrop(s, to: entry, layoutSize: layoutSize, scale: scale)
        Reconciler3D.reconcile(s.nodes, under: entry.content)
        SCNTransaction.commit()

        let aa: SCNAntialiasingMode
        switch s.antialiasing {
        case .none: aa = .none
        case .x2: aa = .multisampling2X
        case .x4: aa = .multisampling4X
        }
        // atTime is constant: everything time-varying already came from `t` above.
        if renderer.scene !== entry.scene { renderer.scene = entry.scene }
        renderer.pointOfView = entry.cameraNode
        let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: aa)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var transparent = false
        if case .transparent = s.background { transparent = true }
        return Self.normalize(cg, clampPremultiplied: transparent)
    }

    /// Copy into a plain 8-bit premultiplied sRGB bitmap (one stable format for the
    /// compositor, and the GPU readback happens here, inside the timing).
    ///
    /// With a transparent background SceneKit's depth of field and bloom blur color but
    /// not alpha, leaving pixels brighter than their coverage (a glowing fringe once
    /// composited). Clamping color to alpha restores valid premultiplied pixels.
    static func normalize(_ cg: CGImage, clampPremultiplied: Bool) -> CGImage? {
        let w = cg.width, h = cg.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cg }
        ctx.setBlendMode(.copy)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        if clampPremultiplied, let base = ctx.data {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = p[i + 3]
                if p[i] > a { p[i] = a }
                if p[i + 1] > a { p[i + 1] = a }
                if p[i + 2] > a { p[i + 2] = a }
            }
        }
        return ctx.makeImage()
    }

    private func entry(for id: String) -> Entry {
        if let e = entries[id] {
            if order.last != id { order.removeAll { $0 == id }; order.append(id) }
            return e
        }
        let e = Entry()
        entries[id] = e
        order.append(id)
        if order.count > entryLimit { entries.removeValue(forKey: order.removeFirst()) }
        return e
    }

    // MARK: stage

    private func applyStage(_ s: Scene3D, to e: Entry, layoutSize: CGSize, scale: CGFloat) {
        let scene = e.scene
        switch s.background {
        case .color(let c): scene.background.contents = Colors3D.ns(c)
        case .transparent: scene.background.contents = NSColor.clear
        case .environment: break  // set below with the environment
        case .swiftUI:
            // Drawn on a camera-locked card instead (see `applyBackdrop`): SceneKit's 2D
            // background image is composited after shadow-only materials and hides their shadows.
            scene.background.contents = NSColor.black
        }

        let envKey: String
        let envImage: CGImage?
        switch s.environment.source {
        case .none: envKey = "none"; envImage = nil
        case .studio:
            envKey = "studio|\(s.environment.rotation)"
            envImage = EnvironmentMaps.studio(rotation: s.environment.rotation)
        case .file(let path):
            let stamp = AssetPaths.resolve(path).map { FileStamp.of($0.path) } ?? "missing"
            envKey = "file|\(path)|\(stamp)|\(s.environment.rotation)"
            envImage = EnvironmentMaps.file(path, rotation: s.environment.rotation)
        }
        // Only re-assign on change: SceneKit pre-filters the map once per contents object.
        // Each renderer gets its own copy of the image: SceneKit keeps GPU state keyed by the
        // contents object, and a second renderer reusing an object the first one prepared
        // renders measurably differently (≈49 dB) from a cold one — a `--jobs` seam.
        if e.environmentKey != envKey {
            e.environmentImage = envImage?.copy()
            scene.lightingEnvironment.contents = e.environmentImage
            e.environmentKey = envKey
        }
        scene.lightingEnvironment.intensity = CGFloat(envImage == nil ? 0 : s.environment.intensity)
        if case .environment = s.background {
            scene.background.contents = envImage ?? NSColor.black
            scene.background.intensity = CGFloat(s.environment.intensity)
        } else {
            scene.background.intensity = 1
        }

        if let fog = s.fog {
            scene.fogColor = Colors3D.ns(fog.color)
            scene.fogStartDistance = CGFloat(fog.start)
            scene.fogEndDistance = CGFloat(fog.end)
            scene.fogDensityExponent = CGFloat(fog.exponent)
        } else {
            scene.fogStartDistance = 0
            scene.fogEndDistance = 0
            scene.fogDensityExponent = 0
        }
    }

    /// A `.view` background is a real card in the scene, locked to the camera just inside
    /// the far plane and sized to fill the frame exactly — so depth of field treats it as
    /// distant background and shadow-catcher floors darken it.
    private func applyBackdrop(_ s: Scene3D, to e: Entry, layoutSize: CGSize, scale: CGFloat) {
        guard case .swiftUI(let view) = s.background else {
            e.backdrop.isHidden = true
            return
        }
        let card = e.backdrop
        card.isHidden = false
        let distance = s.camera.far * 0.9
        let aspect = Double(layoutSize.width / max(1, layoutSize.height))
        let height: Double
        if let ortho = s.camera.orthographicScale {
            height = 2 * ortho
        } else {
            height = 2 * distance * tan(s.camera.fov * .pi / 360)
        }
        let plane = (card.geometry as? SCNPlane) ?? SCNPlane()
        // A hair oversized so no edge pixel samples past the card.
        plane.width = CGFloat(height * aspect * 1.002)
        plane.height = CGFloat(height * 1.002)
        if card.geometry == nil {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.writesToDepthBuffer = false
            plane.materials = [m]
            card.geometry = plane
            card.castsShadow = false
            card.renderingOrder = -1000
            card.name = "swift-render.backdrop"
        }
        card.simdPosition = [0, 0, -Float(distance)]
        card.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        plane.firstMaterial?.diffuse.contents = Textures3D.render(view, width: Double(layoutSize.width),
                                                                  height: Double(layoutSize.height), scale: Double(scale))
    }

    private func applyCamera(_ c: Camera3D, effects fx: Effects3D, aspect: CGFloat, to node: SCNNode) {
        guard let cam = node.camera else { return }
        node.simdPosition = SIMD3<Float>(c.position)
        var q = Rotation3D.lookAt(from: c.position, to: c.target, up: c.up)
        if c.roll != 0 { q = simd_normalize(q * simd_quatd(angle: c.roll * .pi / 180, axis: [0, 0, 1])) }
        node.simdOrientation = Rotation3D.float(q)
        node.simdScale = [1, 1, 1]

        cam.projectionDirection = .vertical
        cam.fieldOfView = CGFloat(c.fov)
        cam.zNear = c.near
        cam.zFar = c.far
        cam.automaticallyAdjustsZRange = false
        cam.usesOrthographicProjection = c.orthographicScale != nil
        cam.orthographicScale = c.orthographicScale ?? 1

        if let dof = c.depthOfField {
            cam.wantsDepthOfField = true
            cam.focusDistance = CGFloat(max(0.001, dof.focusDistance))
            cam.fStop = CGFloat(max(0.1, dof.fStop))
            cam.apertureBladeCount = dof.blades
            cam.focalBlurSampleCount = 48
        } else {
            cam.wantsDepthOfField = false
        }

        cam.wantsHDR = fx.hdr
        cam.wantsExposureAdaptation = false        // adapts over previous frames
        cam.motionBlurIntensity = 0                 // needs the previous frame's transforms
        cam.exposureOffset = CGFloat(fx.exposure)
        cam.averageGray = 0.18
        cam.whitePoint = 1
        cam.minimumExposure = -15
        cam.maximumExposure = 15
        if let b = fx.bloom {
            cam.bloomIntensity = CGFloat(b.intensity)
            cam.bloomThreshold = CGFloat(b.threshold)
            cam.bloomBlurRadius = CGFloat(b.radius)
            cam.bloomIterationCount = 2
        } else {
            cam.bloomIntensity = 0
        }
        cam.screenSpaceAmbientOcclusionIntensity = CGFloat(fx.ambientOcclusion)
        cam.screenSpaceAmbientOcclusionRadius = CGFloat(fx.ambientOcclusionRadius)
        cam.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        cam.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        cam.vignettingIntensity = CGFloat(fx.vignette)
        cam.vignettingPower = fx.vignette > 0 ? 1 : 0
        cam.saturation = CGFloat(fx.saturation)
        cam.contrast = CGFloat(fx.contrast)
        cam.colorFringeStrength = 0
    }
}

// MARK: - Managed nodes

/// An SCNNode the reconciler owns: remembers what it was built for and its managed
/// children, so the next frame can reuse it.
final class ManagedNode: SCNNode {
    enum KindKey: Hashable {
        case group
        case geometry(Geometry3D)
        case model(ModelRef, stamp: String)
        case light
    }

    let kindKey: KindKey
    var managed: [ManagedNode] = []
    /// The node that carries the geometry (self, or an internal child when the mesh
    /// needs its own normalising transform — text, slabs).
    var mesh: SCNNode?
    var ownMaterials: [SCNMaterial] = []
    var model: ModelInstance?

    init(kindKey: KindKey) {
        self.kindKey = kindKey
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("ManagedNode is not decodable") }
}

/// A per-node copy of a loaded model plus its rest pose.
final class ModelInstance {
    struct Rest {
        let node: SCNNode
        let position: SIMD3<Float>
        let orientation: simd_quatf
        let scale: SIMD3<Float>
        let isHidden: Bool
        let opacity: CGFloat
        let materials: [SCNMaterial]
    }

    let root: SCNNode
    var rest: [Rest] = []
    var byName: [String: [Int]] = [:]
    var overrideMaterials: [String: SCNMaterial] = [:]
    var wholeMaterials: [SCNMaterial] = []

    init(template: SCNNode) {
        root = template.clone()
        root.enumerateHierarchy { n, _ in
            // Own meshes' materials (clone() shares them), and nothing that runs on SceneKit's clock.
            if let g = n.geometry?.copy() as? SCNGeometry {
                g.materials = g.materials.map { m in
                    let c = (m.copy() as? SCNMaterial) ?? m
                    Materials3D.sanitize(c)
                    return c
                }
                n.geometry = g
            }
            n.removeAllAnimations()
            n.removeAllActions()
            n.removeAllParticleSystems()
            n.physicsBody = nil
            n.camera = nil
        }
        root.enumerateHierarchy { n, _ in
            let i = rest.count
            rest.append(Rest(node: n, position: n.simdPosition, orientation: n.simdOrientation, scale: n.simdScale,
                             isHidden: n.isHidden, opacity: n.opacity, materials: n.geometry?.materials ?? []))
            if let name = n.name { byName[name, default: []].append(i) }
        }
    }

    func restore() {
        for r in rest {
            r.node.simdPosition = r.position
            r.node.simdOrientation = r.orientation
            r.node.simdScale = r.scale
            r.node.isHidden = r.isHidden
            r.node.opacity = r.opacity
            if let g = r.node.geometry, !r.materials.isEmpty { g.materials = r.materials }
        }
    }
}

// MARK: - Reconciler

@MainActor
enum Reconciler3D {
    static func reconcile(_ descs: [Node3D], under parent: ManagedNode) {
        for (i, d) in descs.enumerated() {
            let key = kindKey(d)
            let node: ManagedNode
            if i < parent.managed.count, parent.managed[i].kindKey == key {
                node = parent.managed[i]
            } else {
                node = make(d, key: key)
                if i < parent.managed.count {
                    parent.managed[i].removeFromParentNode()
                    parent.managed[i] = node
                } else {
                    parent.managed.append(node)
                }
                parent.addChildNode(node)
            }
            apply(d, to: node)
            reconcile(d.children, under: node)
        }
        while parent.managed.count > descs.count {
            parent.managed.removeLast().removeFromParentNode()
        }
    }

    static func kindKey(_ d: Node3D) -> ManagedNode.KindKey {
        switch d.kind {
        case .group: return .group
        case .geometry(let g): return .geometry(g)
        case .model(let ref):
            return .model(ref, stamp: AssetPaths.resolve(ref.path).map { FileStamp.of($0.path) } ?? "missing")
        case .light: return .light
        }
    }

    private static func make(_ d: Node3D, key: ManagedNode.KindKey) -> ManagedNode {
        let n = ManagedNode(kindKey: key)
        switch d.kind {
        case .group: break
        case .geometry(let g):
            let built = Geometries3D.make(g)
            let geometry = (built.geometry.copy() as? SCNGeometry) ?? built.geometry
            if let transform = built.meshTransform {
                let mesh = SCNNode(geometry: geometry)
                mesh.simdTransform = transform
                mesh.name = "mesh"
                n.addChildNode(mesh)
                n.mesh = mesh
            } else {
                n.geometry = geometry
                n.mesh = n
            }
        case .model(let ref):
            if let loaded = Models3D.template(ref.path) {
                let inst = ModelInstance(template: loaded.node)
                let fit = SCNNode()
                fit.name = "fit"
                fit.simdTransform = loaded.fitTransform(ref.fit, anchor: ref.anchor)
                fit.addChildNode(inst.root)
                n.addChildNode(fit)
                n.model = inst
            }
        case .light:
            n.light = SCNLight()
        }
        return n
    }

    private static func apply(_ d: Node3D, to n: ManagedNode) {
        n.name = d.name
        n.simdPosition = SIMD3<Float>(d.position)
        n.simdOrientation = Rotation3D.float(d.orientation)
        n.simdScale = SIMD3<Float>(d.scale)
        n.opacity = CGFloat(d.opacity)
        n.isHidden = d.isHidden
        n.renderingOrder = d.renderingOrder
        n.castsShadow = d.castsShadow
        n.mesh?.castsShadow = d.castsShadow
        n.mesh?.renderingOrder = d.renderingOrder

        switch d.kind {
        case .group: break
        case .geometry(let g):
            guard let geometry = n.mesh?.geometry else { break }
            let count = max(1, Geometries3D.elementCount(g, geometry))
            let descs = d.materials.isEmpty ? [Material3D()] : d.materials
            while n.ownMaterials.count < count { n.ownMaterials.append(SCNMaterial()) }
            if n.ownMaterials.count > count { n.ownMaterials.removeLast(n.ownMaterials.count - count) }
            for i in 0..<count { Materials3D.apply(descs[min(i, descs.count - 1)], to: n.ownMaterials[i]) }
            if geometry.materials.count != count || zip(geometry.materials, n.ownMaterials).contains(where: { $0 !== $1 }) {
                geometry.materials = n.ownMaterials
            }
            if case .floor(let reflectivity, let falloff) = g, let floor = geometry as? SCNFloor {
                floor.reflectivity = CGFloat(reflectivity)
                floor.reflectionFalloffEnd = CGFloat(falloff)
                floor.reflectionResolutionScaleFactor = 1
            }
        case .model:
            guard let inst = n.model else { break }
            inst.restore()
            if !d.materials.isEmpty {
                while inst.wholeMaterials.count < d.materials.count { inst.wholeMaterials.append(SCNMaterial()) }
                for (i, m) in d.materials.enumerated() { Materials3D.apply(m, to: inst.wholeMaterials[i]) }
                for r in inst.rest where r.node.geometry != nil {
                    r.node.geometry?.materials = Array(inst.wholeMaterials.prefix(d.materials.count))
                }
            }
            for part in d.parts {
                guard let idx = inst.byName[part.name] else {
                    Models3D.warnMissingPart(part.name)
                    continue
                }
                for i in idx {
                    let r = inst.rest[i]
                    r.node.simdPosition = r.position + SIMD3<Float>(part.offset)
                    r.node.simdOrientation = simd_normalize(Rotation3D.float(part.rotation) * r.orientation)
                    r.node.simdScale = r.scale * SIMD3<Float>(part.scale)
                    if let h = part.isHidden { r.node.isHidden = h }
                    if let o = part.opacity { r.node.opacity = CGFloat(o) }
                    if let m = part.material {
                        let mat = inst.overrideMaterials[part.name] ?? SCNMaterial()
                        inst.overrideMaterials[part.name] = mat
                        Materials3D.apply(m, to: mat)
                        r.node.enumerateHierarchy { c, _ in c.geometry?.materials = [mat] }
                    }
                }
            }
        case .light(let l):
            if let light = n.light { Lights3D.apply(l, to: light) }
        }
    }
}

// MARK: - Lights

@MainActor
enum Lights3D {
    static func apply(_ l: Light3D, to light: SCNLight) {
        switch l.kind {
        case .directional: light.type = .directional
        case .spot(let inner, let outer):
            light.type = .spot
            light.spotInnerAngle = CGFloat(inner)
            light.spotOuterAngle = CGFloat(outer)
        case .omni: light.type = .omni
        case .area(let w, let h):
            light.type = .area
            light.areaType = .rectangle
            light.areaExtents = SIMD3<Float>(Float(w), Float(h), 1)
            light.doubleSided = false
        case .ambient: light.type = .ambient
        }
        light.color = Colors3D.ns(l.color)
        light.temperature = CGFloat(l.temperature ?? 6500)
        light.intensity = CGFloat(l.intensity)
        if let a = l.attenuation {
            light.attenuationStartDistance = CGFloat(a.lowerBound)
            light.attenuationEndDistance = CGFloat(a.upperBound)
            light.attenuationFalloffExponent = 2
        } else {
            light.attenuationStartDistance = 0
            light.attenuationEndDistance = 0
        }
        let canShadow: Bool
        switch l.kind {
        case .directional, .spot: canShadow = true
        default: canShadow = false
        }
        if let s = l.shadow, canShadow {
            light.castsShadow = true
            light.shadowColor = Colors3D.ns(s.color)
            light.shadowRadius = CGFloat(s.softness)
            light.shadowSampleCount = max(1, s.samples)
            light.shadowMapSize = CGSize(width: s.mapSize, height: s.mapSize)
            light.shadowMode = .deferred
            light.shadowBias = CGFloat(s.bias)
            light.zNear = 0.01
            light.zFar = 100
            if case .directional = l.kind {
                light.automaticallyAdjustsShadowProjection = false
                light.orthographicScale = CGFloat(s.extent)
            } else {
                light.automaticallyAdjustsShadowProjection = true
            }
        } else {
            light.castsShadow = false
        }
    }
}

// MARK: - Colors

enum Colors3D {
    static func ns(_ c: Color) -> NSColor {
        let ns = NSColor(c)
        return ns.usingColorSpace(.extendedSRGB) ?? ns.usingColorSpace(.sRGB) ?? ns
    }
}
