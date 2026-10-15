import SwiftUI
import simd

/// A 3D vector in scene units. By convention 1 unit = 1 metre, which keeps depth of
/// field, light falloff and shadow softness physically sensible. Array literals work:
/// `[0, 1.2, 3]`.
public typealias Vec3 = SIMD3<Double>

/// One node of a ``Scene3D`` description: a value, rebuilt every frame from `t`.
///
/// You rarely build a `Node3D` directly. Use the primitives (``Box3D``, ``Sphere3D``,
/// ``Slab3D``, ``Text3D``, ``Model3D``, ``Floor3D``, ``Light3D``, ``Group3D`` …) and their
/// modifiers, which all return a `Node3D`:
///
///     Slab3D(width: 0.075, height: 0.155, depth: 0.008, cornerRadius: 0.012)
///         .position(0, 0.08, 0)
///         .rotation(y: Motion3D.turntable(t, degreesPerSecond: 12))
///
/// The engine reconciles the description onto a cached SceneKit graph and sets
/// **every** property every frame, so a frame depends only on its description,
/// never on the frame rendered before it.
public struct Node3D: Object3D {
    /// What the node draws.
    public enum Kind {
        case group
        case geometry(Geometry3D)
        case model(ModelRef)
        case light(Light3D)
    }

    public var kind: Kind
    /// Optional name (shows up in SceneKit's graph; handy for debugging).
    public var name: String?
    public var position: Vec3 = .zero
    /// Orientation. Compose with ``rotation(x:y:z:)``, ``rotated(_:axis:)`` and ``look(at:up:)``.
    public var orientation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    public var scale: Vec3 = [1, 1, 1]
    /// Materials for geometry nodes (one per geometry element; the last one repeats).
    /// For models, a non-empty list replaces every material of the model.
    public var materials: [Material3D] = []
    public var children: [Node3D] = []
    public var castsShadow: Bool = true
    public var opacity: Double = 1
    public var isHidden: Bool = false
    /// Higher draws later (useful for transparent overlays).
    public var renderingOrder: Int = 0
    /// Per-part overrides for loaded models (see ``Object3D/part(_:_:)``).
    public var parts: [Part3D] = []

    public init(_ kind: Kind, children: [Node3D] = []) {
        self.kind = kind
        self.children = children
    }

    public var node: Node3D { self }
}

/// Anything that can sit in a ``Scene3D`` builder. All modifiers live here, so
/// `Box3D(…).position(…)` and `someNode.position(…)` read the same.
public protocol Object3D {
    var node: Node3D { get }
}

// MARK: - Modifiers

public extension Object3D {
    /// Absolute position in the parent's space.
    func position(_ x: Double, _ y: Double, _ z: Double) -> Node3D { position([x, y, z]) }
    func position(_ p: Vec3) -> Node3D { var n = node; n.position = p; return n }
    /// Adds to the current position.
    func offset(_ d: Vec3) -> Node3D { var n = node; n.position += d; return n }

    /// Sets the orientation from Euler angles in **degrees**, applied Z, then X, then Y
    /// (roll, pitch, yaw) — so `y:` always spins about the world-up axis.
    func rotation(x: Double = 0, y: Double = 0, z: Double = 0) -> Node3D {
        var n = node; n.orientation = Rotation3D.euler(x: x, y: y, z: z); return n
    }
    /// Rotates by `degrees` about `axis`, on top of the current orientation (in the parent's space).
    func rotated(_ degrees: Double, axis: Vec3) -> Node3D {
        var n = node
        n.orientation = simd_normalize(simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis)) * n.orientation)
        return n
    }
    /// Points the node's −Z axis at `target` (SceneKit's forward for cameras and lights).
    func look(at target: Vec3, up: Vec3 = [0, 1, 0]) -> Node3D {
        var n = node; n.orientation = Rotation3D.lookAt(from: n.position, to: target, up: up); return n
    }
    func scale(_ s: Double) -> Node3D { var n = node; n.scale = [s, s, s]; return n }
    func scale(_ s: Vec3) -> Node3D { var n = node; n.scale = s; return n }

    /// One material for every element of the geometry (or every mesh of a model).
    func material(_ m: Material3D) -> Node3D { var n = node; n.materials = [m]; return n }
    /// One material per geometry element, in SceneKit's element order.
    func materials(_ ms: [Material3D]) -> Node3D { var n = node; n.materials = ms; return n }
    func castsShadow(_ on: Bool) -> Node3D { var n = node; n.castsShadow = on; return n }
    func opacity(_ o: Double) -> Node3D { var n = node; n.opacity = o; return n }
    func hidden(_ h: Bool = true) -> Node3D { var n = node; n.isHidden = h; return n }
    func named(_ name: String) -> Node3D { var n = node; n.name = name; return n }
    func renderingOrder(_ o: Int) -> Node3D { var n = node; n.renderingOrder = o; return n }
    /// Attach child nodes (they move with this one).
    func children(@Scene3DBuilder _ content: () -> [Node3D]) -> Node3D {
        var n = node; n.children += content(); return n
    }
}

/// Rotation helpers (degrees in, quaternions out).
public enum Rotation3D {
    /// Z, then X, then Y (roll, pitch, yaw) — `y` is a turntable spin.
    public static func euler(x: Double, y: Double, z: Double) -> simd_quatd {
        let r = Double.pi / 180
        let qx = simd_quatd(angle: x * r, axis: [1, 0, 0])
        let qy = simd_quatd(angle: y * r, axis: [0, 1, 0])
        let qz = simd_quatd(angle: z * r, axis: [0, 0, 1])
        return simd_normalize(qy * qx * qz)
    }

    /// Orientation whose −Z axis points from `from` to `to`.
    public static func lookAt(from: Vec3, to: Vec3, up: Vec3 = [0, 1, 0]) -> simd_quatd {
        var f = to - from
        if simd_length(f) < 1e-9 { f = [0, 0, -1] }
        f = simd_normalize(f)
        var u = simd_normalize(up)
        if abs(simd_dot(f, u)) > 0.9999 { u = abs(f.y) < 0.9 ? [0, 1, 0] : [0, 0, 1] }
        let back = -f
        let right = simd_normalize(simd_cross(u, back))
        let trueUp = simd_cross(back, right)
        let m = simd_double3x3(columns: (right, trueUp, back))
        return simd_normalize(simd_quatd(m))
    }

    static func float(_ q: simd_quatd) -> simd_quatf {
        simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
    }
}

// MARK: - Builder

/// Builds a list of ``Node3D`` from primitives, `if`, `switch` and `for`.
@resultBuilder
public enum Scene3DBuilder {
    public static func buildExpression(_ o: some Object3D) -> [Node3D] { [o.node] }
    public static func buildExpression(_ nodes: [Node3D]) -> [Node3D] { nodes }
    public static func buildBlock(_ parts: [Node3D]...) -> [Node3D] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Node3D]?) -> [Node3D] { part ?? [] }
    public static func buildEither(first: [Node3D]) -> [Node3D] { first }
    public static func buildEither(second: [Node3D]) -> [Node3D] { second }
    public static func buildArray(_ parts: [[Node3D]]) -> [Node3D] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [Node3D]) -> [Node3D] { part }
}

/// A transform-only parent for other nodes.
public struct Group3D: Object3D {
    public let node: Node3D
    public init(@Scene3DBuilder _ content: () -> [Node3D]) {
        node = Node3D(.group, children: content())
    }
}

// MARK: - Geometry

/// Hashable geometry description; equal descriptions share one cached mesh.
public enum Geometry3D: Hashable {
    case box(width: Double, height: Double, length: Double, chamfer: Double)
    case sphere(radius: Double, segments: Int)
    case plane(width: Double, height: Double, cornerRadius: Double)
    case cylinder(radius: Double, height: Double)
    case cone(topRadius: Double, bottomRadius: Double, height: Double)
    case torus(ringRadius: Double, pipeRadius: Double)
    case capsule(radius: Double, height: Double)
    /// Rounded rectangle extruded along Z with rounded edges — a phone, a tablet, a card.
    case slab(width: Double, height: Double, depth: Double, cornerRadius: Double, edgeRadius: Double)
    case text(String, font: String?, weight: Double, size: Double, depth: Double, chamfer: Double)
    case floor(reflectivity: Double, falloff: Double)
}

/// A box, optionally with rounded (chamfered) edges. Elements: front, right, back, left, top, bottom.
public struct Box3D: Object3D {
    public let node: Node3D
    public init(width: Double = 1, height: Double = 1, length: Double = 1, chamfer: Double = 0) {
        node = Node3D(.geometry(.box(width: width, height: height, length: length, chamfer: chamfer)))
    }
    public init(size: Double, chamfer: Double = 0) { self.init(width: size, height: size, length: size, chamfer: chamfer) }
}

public struct Sphere3D: Object3D {
    public let node: Node3D
    public init(radius: Double = 0.5, segments: Int = 96) {
        node = Node3D(.geometry(.sphere(radius: radius, segments: segments)))
    }
}

/// A plane in the XY plane facing +Z, optionally with rounded corners.
public struct Plane3D: Object3D {
    public let node: Node3D
    public init(width: Double = 1, height: Double = 1, cornerRadius: Double = 0) {
        node = Node3D(.geometry(.plane(width: width, height: height, cornerRadius: cornerRadius)))
    }
}

/// A cylinder along Y. Elements: side, top, bottom.
public struct Cylinder3D: Object3D {
    public let node: Node3D
    public init(radius: Double = 0.5, height: Double = 1) {
        node = Node3D(.geometry(.cylinder(radius: radius, height: height)))
    }
}

public struct Cone3D: Object3D {
    public let node: Node3D
    public init(topRadius: Double = 0, bottomRadius: Double = 0.5, height: Double = 1) {
        node = Node3D(.geometry(.cone(topRadius: topRadius, bottomRadius: bottomRadius, height: height)))
    }
}

public struct Torus3D: Object3D {
    public let node: Node3D
    public init(ringRadius: Double = 0.5, pipeRadius: Double = 0.15) {
        node = Node3D(.geometry(.torus(ringRadius: ringRadius, pipeRadius: pipeRadius)))
    }
}

public struct Capsule3D: Object3D {
    public let node: Node3D
    public init(radius: Double = 0.25, height: Double = 1) {
        node = Node3D(.geometry(.capsule(radius: radius, height: height)))
    }
}

/// A rounded slab: a rounded rectangle (`cornerRadius`) extruded to `depth` with
/// rounded edges (`edgeRadius`, defaults to just under half the depth). Centred on
/// the origin, front face toward +Z. Elements: front, back, sides, front edge, back edge.
///
/// Pass `screen:` to put a material (usually a ``Texture3D/view(width:height:scale:content:)``)
/// on an inset rounded panel just in front of the front face — a device in two lines.
public struct Slab3D: Object3D {
    public let node: Node3D
    public init(width: Double, height: Double, depth: Double, cornerRadius: Double,
                edgeRadius: Double? = nil, screen: Material3D? = nil, screenInset: Double? = nil) {
        let edge = min(edgeRadius ?? depth * 0.45, depth * 0.49, cornerRadius * 0.99)
        var n = Node3D(.geometry(.slab(width: width, height: height, depth: depth,
                                       cornerRadius: cornerRadius, edgeRadius: edge)))
        if let screen {
            let inset = screenInset ?? min(width, height) * 0.045
            let w = max(0.001, width - 2 * inset), h = max(0.001, height - 2 * inset)
            let r = max(0, cornerRadius - inset)
            n.children = [Plane3D(width: w, height: h, cornerRadius: r)
                .material(screen).position(0, 0, depth / 2 + depth * 0.004).named("screen")]
        }
        node = n
    }
}

/// Extruded 3D text, centred on the origin. `size` is the cap-to-baseline font size in
/// scene units; `font` is a PostScript or family name (system font when nil).
/// Elements: front, back, sides, chamfer front, chamfer back.
public struct Text3D: Object3D {
    public let node: Node3D
    public init(_ string: String, size: Double = 0.2, depth: Double = 0.04, font: String? = nil,
                weight: Font.Weight = .bold, chamfer: Double = 0) {
        node = Node3D(.geometry(.text(string, font: font, weight: Self.weightValue(weight),
                                      size: size, depth: depth, chamfer: chamfer)))
    }

    static func weightValue(_ w: Font.Weight) -> Double {
        switch w {
        case .ultraLight: return -0.8
        case .thin: return -0.6
        case .light: return -0.4
        case .regular: return 0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        case .black: return 0.62
        default: return 0
        }
    }
}

/// An infinite floor at y = 0 (move it with `.position`). Use ``Material3D/shadowCatcher(opacity:)``
/// to keep only the shadows — the way to composite a product onto any background.
public struct Floor3D: Object3D {
    public let node: Node3D
    public init(reflectivity: Double = 0, falloff: Double = 0.5, material: Material3D = .matte(Color(white: 0.06))) {
        var n = Node3D(.geometry(.floor(reflectivity: reflectivity, falloff: falloff)))
        n.materials = [material]
        node = n
    }
}

// MARK: - Models

/// A loaded model reference. Equal references share one cached template.
public struct ModelRef: Hashable {
    public var path: String
    public var fit: Fit3D?
    public var anchor: Anchor3D
}

/// Normalising a model's size on load (models come in all units).
public enum Fit3D: Hashable {
    /// Scale so the bounding box's height is this many units.
    case height(Double)
    /// Scale so the bounding box's largest side is this many units.
    case size(Double)
}

/// Where a fitted model's origin goes.
public enum Anchor3D: Hashable {
    /// The model's own origin (no recentring).
    case original
    /// The bounding-box centre.
    case center
    /// The centre of the bounding box's bottom face — sits on a floor at y = 0.
    case bottom
}

/// A model file: USDZ, USD, OBJ, SCN, DAE, ABC — anything `SCNScene(url:)` reads.
/// Paths resolve through ``AssetPaths``. The file is loaded once per process (and
/// reloaded when it changes on disk); each node gets its own copy of the meshes'
/// materials, so overrides never leak between instances.
///
///     Model3D("models/robot.usdz", fit: .height(1.6), anchor: .bottom)
///         .part("Head") { $0.rotated(Motion3D.oscillate(t, degrees: 12, period: 4), axis: [0, 1, 0]) }
///         .part("Visor") { $0.material(.emissive(.cyan, intensity: 4)) }
///
/// Embedded animations are not played (they would run on SceneKit's clock); pose
/// parts from `t` with ``Object3D/part(_:_:)`` instead.
public struct Model3D: Object3D {
    public var node: Node3D
    public init(_ path: String, fit: Fit3D? = nil, anchor: Anchor3D = .original) {
        node = Node3D(.model(ModelRef(path: path, fit: fit, anchor: fit == nil && anchor == .original ? .original : anchor)))
    }

}

public extension Object3D {
    /// Adjust a named node inside a ``Model3D`` (searched recursively). Transforms are
    /// relative to the part's rest pose in the file, and every frame starts from that
    /// rest pose. Ignored on nodes that are not models.
    func part(_ name: String, _ edit: (Part3D) -> Part3D) -> Node3D {
        var n = node
        n.parts.append(edit(Part3D(name: name)))
        return n
    }
}

/// An override for one named node of a ``Model3D``, relative to its rest pose.
public struct Part3D {
    public let name: String
    public var offset: Vec3 = .zero
    public var rotation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    public var scale: Vec3 = [1, 1, 1]
    public var isHidden: Bool?
    public var opacity: Double?
    public var material: Material3D?

    public init(name: String) { self.name = name }

    /// Moves the part by `d` (in its parent's space).
    public func offset(_ d: Vec3) -> Part3D { var p = self; p.offset += d; return p }
    /// Rotates the part about its own pivot, on top of its rest orientation.
    public func rotated(_ degrees: Double, axis: Vec3) -> Part3D {
        var p = self
        p.rotation = simd_normalize(simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis)) * p.rotation)
        return p
    }
    public func scaled(_ s: Double) -> Part3D { var p = self; p.scale *= s; return p }
    public func hidden(_ h: Bool = true) -> Part3D { var p = self; p.isHidden = h; return p }
    public func opacity(_ o: Double) -> Part3D { var p = self; p.opacity = o; return p }
    /// Replaces every material on this part's geometry.
    public func material(_ m: Material3D) -> Part3D { var p = self; p.material = m; return p }
}
