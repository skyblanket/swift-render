import AppKit
import ImageIO
import SceneKit
import SwiftUI
import simd

// MARK: - Geometry cache

/// Builds and caches meshes by their hashable description. Nodes take a `copy()`
/// (shared vertex buffers, own materials).
@MainActor
enum Geometries3D {
    struct Built {
        let geometry: SCNGeometry
        /// Internal transform for meshes built at a comfortable tessellation scale.
        let meshTransform: simd_float4x4?
    }

    private static var cache: [Geometry3D: Built] = [:]

    static func purge() { cache = [:] }

    static func make(_ g: Geometry3D) -> Built {
        if let hit = cache[g] { return hit }
        let built = build(g)
        cache[g] = built
        return built
    }

    static func elementCount(_ g: Geometry3D, _ geometry: SCNGeometry) -> Int {
        geometry.elementCount
    }

    private static func build(_ g: Geometry3D) -> Built {
        switch g {
        case let .box(w, h, l, chamfer):
            let b = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
            b.chamferSegmentCount = 12
            return Built(geometry: b, meshTransform: nil)
        case let .sphere(r, segments):
            let s = SCNSphere(radius: r)
            s.segmentCount = max(8, segments)
            return Built(geometry: s, meshTransform: nil)
        case let .plane(w, h, corner):
            let p = SCNPlane(width: w, height: h)
            p.cornerRadius = corner
            p.cornerSegmentCount = 24
            return Built(geometry: p, meshTransform: nil)
        case let .cylinder(r, h):
            let c = SCNCylinder(radius: r, height: h)
            c.radialSegmentCount = 96
            return Built(geometry: c, meshTransform: nil)
        case let .cone(top, bottom, h):
            let c = SCNCone(topRadius: top, bottomRadius: bottom, height: h)
            c.radialSegmentCount = 96
            return Built(geometry: c, meshTransform: nil)
        case let .torus(ring, pipe):
            let t = SCNTorus(ringRadius: ring, pipeRadius: pipe)
            t.ringSegmentCount = 128
            t.pipeSegmentCount = 48
            return Built(geometry: t, meshTransform: nil)
        case let .capsule(r, h):
            let c = SCNCapsule(capRadius: r, height: h)
            c.radialSegmentCount = 64
            return Built(geometry: c, meshTransform: nil)
        case let .slab(w, h, d, corner, edge):
            return slab(width: w, height: h, depth: d, corner: corner, edge: edge)
        case let .text(string, font, weight, size, depth, chamfer):
            return text(string, font: font, weight: weight, size: size, depth: depth, chamfer: chamfer)
        case .floor:
            return Built(geometry: SCNFloor(), meshTransform: nil)
        }
    }

    /// SCNShape tessellates in path units, so tiny (metre-scale) paths come out faceted.
    /// Build at a normalised size of ~10 units and scale back with the mesh transform.
    /// A procedural rounded slab (SCNShape's chamfered corners produce degenerate normals
    /// that bloom/DOF smear into black blocks). Smooth per-vertex normals, UVs that map
    /// the front face like a screen. Elements: front cap, back cap, sides (incl. rounded edges).
    static func slab(width: Double, height: Double, depth: Double, corner: Double, edge: Double) -> Built {
        let hw = width / 2, hh = height / 2, hd = depth / 2
        let r = max(0, min(corner, min(hw, hh)))
        let e = max(0, min(edge, r, hd))
        let perCorner = 24, profileSteps = 12
        // Outline directions and corner centres, counter-clockwise from the bottom-right corner.
        var dirs: [SIMD2<Double>] = [], centres: [SIMD2<Double>] = []
        let corners: [(SIMD2<Double>, Double)] = [([hw - r, -hh + r], -90), ([hw - r, hh - r], 0),
                                                  ([-hw + r, hh - r], 90), ([-hw + r, -hh + r], 180)]
        for (c, a0) in corners {
            for k in 0..<perCorner {
                let a = (a0 + 90 * Double(k) / Double(perCorner - 1)) * .pi / 180
                dirs.append([cos(a), sin(a)]); centres.append(c)
            }
        }
        let n = dirs.count
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = []
        // Rings along the edge profile: φ = 0 faces +Z, 90° faces sideways, 180° faces −Z.
        var phis: [Double] = []
        for i in 0...profileSteps { phis.append(Double(i) / Double(profileSteps) * 90) }
        for i in 0...profileSteps { phis.append(90 + Double(i) / Double(profileSteps) * 90) }
        var perimeter: [Double] = [0]
        for i in 1...n {
            let a = centres[(i - 1) % n] + dirs[(i - 1) % n] * r, b = centres[i % n] + dirs[i % n] * r
            perimeter.append(perimeter[i - 1] + simd_length(b - a))
        }
        let total = max(perimeter[n], 1e-9)
        for (ri, phiDeg) in phis.enumerated() {
            let phi = phiDeg * .pi / 180
            let radius = r - e + e * sin(phi)
            let front = ri <= profileSteps
            let z = front ? (hd - e) + e * cos(phi) : -(hd - e) + e * cos(phi)
            for i in 0..<n {
                let p = centres[i] + dirs[i] * radius
                pos.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(z)))
                nor.append(simd_normalize(SIMD3<Float>(Float(dirs[i].x * sin(phi)), Float(dirs[i].y * sin(phi)), Float(cos(phi)))))
                uv.append([Float(perimeter[i] / total), Float(ri) / Float(phis.count - 1)])
            }
        }
        var sides: [UInt32] = []
        for ri in 0..<(phis.count - 1) {
            let a = UInt32(ri * n), b = UInt32((ri + 1) * n)
            for i in 0..<n {
                let j = UInt32((i + 1) % n), ii = UInt32(i)
                sides += [a + ii, b + ii, a + j, a + j, b + ii, b + j]
            }
        }
        func cap(z: Double, normalZ: Float) -> [UInt32] {
            let base = UInt32(pos.count)
            pos.append([0, 0, Float(z)]); nor.append([0, 0, normalZ]); uv.append([0.5, 0.5])
            let inset = r - e
            for i in 0..<n {
                let p = centres[i] + dirs[i] * inset
                pos.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(z)))
                nor.append([0, 0, normalZ])
                // Front: u left→right, v top→bottom (images read upright). Back: mirrored in u.
                let u = Float(p.x / width + 0.5), v = Float(0.5 - p.y / height)
                uv.append([normalZ > 0 ? u : 1 - u, v])
            }
            var idx: [UInt32] = []
            for i in 0..<n {
                let a = base + 1 + UInt32(i), b = base + 1 + UInt32((i + 1) % n)
                idx += normalZ > 0 ? [base, a, b] : [base, b, a]
            }
            return idx
        }
        let frontIdx = cap(z: hd, normalZ: 1)
        let backIdx = cap(z: -hd, normalZ: -1)
        return Built(geometry: Mesh3D.geometry(positions: pos, normals: nor, uvs: uv,
                                               elements: [frontIdx, backIdx, sides]), meshTransform: nil)
    }

    /// Quarter-circle chamfer profile from (0, 1) to (1, 0) — rounded edges, not bevels.
    private static func roundProfile() -> NSBezierPath {
        let p = NSBezierPath()
        let steps = 24
        for i in 0...steps {
            let a = Double(i) / Double(steps) * .pi / 2
            let pt = NSPoint(x: sin(a), y: cos(a))
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.flatness = 0.001
        return p
    }

    private static func text(_ string: String, font name: String?, weight: Double, size: Double,
                             depth: Double, chamfer: Double) -> Built {
        let pointSize: CGFloat = 100
        let k = Double(pointSize) / max(size, 1e-6)
        let font = name.flatMap { NSFont(name: $0, size: pointSize) }
            ?? NSFont.systemFont(ofSize: pointSize, weight: NSFont.Weight(rawValue: CGFloat(weight)))
        let text = SCNText(string: string, extrusionDepth: depth * k)
        text.font = font
        text.flatness = 0.15
        text.chamferRadius = chamfer * k
        if chamfer > 0 { text.chamferProfile = roundProfile() }
        let (lo, hi) = text.boundingBox
        let center = SIMD3<Float>(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z + hi.z) / 2)
        let s = Float(1 / k)
        var m = simd_float4x4(diagonal: [s, s, s, 1])
        m.columns.3 = SIMD4<Float>(-center * s, 1)
        return Built(geometry: text, meshTransform: m)
    }
}

// MARK: - Materials

@MainActor
enum Materials3D {
    static let minRoughness: Double = 0.06
    static let minClearcoatRoughness: Double = 0.1

    static func apply(_ m: Material3D, to mat: SCNMaterial) {
        switch m.model {
        case .physical: mat.lightingModel = .physicallyBased
        case .constant: mat.lightingModel = .constant
        case .shadowOnly: mat.lightingModel = .shadowOnly
        case .lambert: mat.lightingModel = .lambert
        case .blinn: mat.lightingModel = .blinn
        }
        set(mat.diffuse, m.base, tiling: m.tiling)
        set(mat.metalness, m.metalness, tiling: m.tiling)
        // Near-zero roughness makes the analytic-light specular peak overflow half floats (Inf),
        // which bloom and depth of field then smear into black blocks. Clamp to safe minimums.
        if case .value(let v) = m.roughness {
            set(mat.roughness, .value(max(minRoughness, v)), tiling: m.tiling)
        } else {
            set(mat.roughness, m.roughness, tiling: m.tiling)
        }
        set(mat.emission, m.emission ?? .color(.black), tiling: m.tiling)
        mat.emission.intensity = CGFloat(m.emissionIntensity)
        set(mat.normal, m.normal, tiling: m.tiling)
        mat.normal.intensity = CGFloat(m.normalIntensity)
        set(mat.ambientOcclusion, m.ambientOcclusion, tiling: m.tiling)
        mat.clearCoat.contents = NSNumber(value: m.clearcoat)
        mat.clearCoatRoughness.contents = NSNumber(value: max(minClearcoatRoughness, m.clearcoatRoughness))
        mat.transparency = CGFloat(m.opacity)
        mat.transparencyMode = m.opacity < 1 ? .dualLayer : .default
        mat.blendMode = .alpha
        mat.isDoubleSided = m.doubleSided
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true
        mat.locksAmbientWithDiffuse = true
        sanitize(mat)
    }

    /// A specular peak at a grazing silhouette pixel (seen with spot lights on metals) can be
    /// finite but huge; SceneKit's depth-of-field pass sums it in half precision, overflows to
    /// Inf, and smears a black block across the edge. This fragment modifier drops non-finite
    /// values and caps radiance at 48 (far above white after exposure, so bloom keeps its headroom).
    static let finiteModifier = """
    #pragma body
    // Bit test, not isnan(): Metal's fast math folds isnan/isinf away.
    uint4 srBits = as_type<uint4>(float4(_output.color));
    if (any((srBits & 0x7f800000u) == 0x7f800000u)) { _output.color = float4(0.0, 0.0, 0.0, 1.0); }
    _output.color.rgb = min(_output.color.rgb, 48.0);
    """

    /// Adds the modifier unless the material already has its own fragment modifier.
    static func sanitize(_ mat: SCNMaterial) {
        guard mat.shaderModifiers?[.fragment] == nil else { return }
        var mods = mat.shaderModifiers ?? [:]
        mods[.fragment] = finiteModifier
        mat.shaderModifiers = mods
    }

    private static func set(_ p: SCNMaterialProperty, _ tex: Texture3D?, tiling: SIMD2<Double>) {
        guard let tex else { p.contents = nil; return }
        p.contents = Textures3D.contents(tex)
        let isImage: Bool
        switch tex {
        case .image, .cgImage, .swiftUI: isImage = true
        default: isImage = false
        }
        if isImage, tiling != [1, 1] {
            p.contentsTransform = SCNMatrix4MakeScale(CGFloat(tiling.x), CGFloat(tiling.y), 1)
            p.wrapS = .repeat; p.wrapT = .repeat
        } else {
            p.contentsTransform = SCNMatrix4Identity
            p.wrapS = .clamp; p.wrapT = .clamp
        }
        p.mipFilter = isImage ? .linear : .none
        p.minificationFilter = .linear
        p.magnificationFilter = .linear
        p.maxAnisotropy = isImage ? 8 : 1
    }
}

// MARK: - Textures

@MainActor
enum Textures3D {
    private static var images: [String: CGImage] = [:]

    static func purge() { images = [:] }

    static func contents(_ tex: Texture3D) -> Any? {
        switch tex {
        case .color(let c): return Colors3D.ns(c)
        case .value(let v): return NSNumber(value: v)
        case .cgImage(let cg): return cg
        case .image(let path): return MediaLibrary.image(path)
        case let .swiftUI(w, h, scale, content): return render(content, width: w, height: h, scale: scale)
        }
    }

    /// Renders a SwiftUI view to an opaque-backed bitmap for a texture. A nested
    /// ImageRenderer starts a fresh environment, so the view sees its own size only.
    static func render(_ view: AnyView, width: Double, height: Double, scale: Double) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

// MARK: - Models

@MainActor
enum Models3D {
    final class Loaded {
        let node: SCNNode
        /// Bounding box of every mesh in the template's root space.
        let bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

        init(node: SCNNode) {
            self.node = node
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            var any = false
            node.enumerateHierarchy { n, _ in
                guard let g = n.geometry else { return }
                let (a, b) = g.boundingBox
                for corner in 0..<8 {
                    let p = SIMD3<Float>(corner & 1 == 0 ? Float(a.x) : Float(b.x),
                                         corner & 2 == 0 ? Float(a.y) : Float(b.y),
                                         corner & 4 == 0 ? Float(a.z) : Float(b.z))
                    let w = n.simdConvertPosition(p, to: node)
                    lo = simd_min(lo, w); hi = simd_max(hi, w); any = true
                }
            }
            bounds = any ? (lo, hi) : nil
        }

        func fitTransform(_ fit: Fit3D?, anchor: Anchor3D) -> simd_float4x4 {
            guard let b = bounds else { return matrix_identity_float4x4 }
            let size = b.max - b.min
            var s: Float = 1
            switch fit {
            case .height(let h)?: s = size.y > 0 ? Float(h) / size.y : 1
            case .size(let v)?: s = max(size.x, size.y, size.z) > 0 ? Float(v) / max(size.x, size.y, size.z) : 1
            case nil: s = 1
            }
            var origin = SIMD3<Float>(repeating: 0)
            switch anchor {
            case .original: origin = .zero
            case .center: origin = (b.min + b.max) / 2
            case .bottom: origin = [(b.min.x + b.max.x) / 2, b.min.y, (b.min.z + b.max.z) / 2]
            }
            var m = simd_float4x4(diagonal: [s, s, s, 1])
            m.columns.3 = SIMD4<Float>(-origin * s, 1)
            return m
        }
    }

    private static var cache: [String: Loaded] = [:]
    private static var warned: Set<String> = []

    static func purge() { cache = [:]; warned = [] }

    /// The cached template for `path` (reloaded when the file changes on disk).
    static func template(_ path: String) -> Loaded? {
        guard let url = AssetPaths.resolve(path) else {
            warnOnce("model not found: \(path)")
            return nil
        }
        let key = url.path + "|" + FileStamp.of(url.path)
        if let hit = cache[key] { return hit }
        do {
            let scene = try SCNScene(url: url, options: [
                .checkConsistency: false,
                .convertToYUp: true,
                .createNormalsIfAbsent: true,
                .flattenScene: false,
                .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay,
            ])
            let root = SCNNode()
            for child in scene.rootNode.childNodes { root.addChildNode(child) }
            let loaded = Loaded(node: root)
            cache[key] = loaded
            return loaded
        } catch {
            warnOnce("model unreadable: \(path) (\(error.localizedDescription))")
            return nil
        }
    }

    static func warnMissingPart(_ name: String) { warnOnce("model part not found: \(name)") }

    private static func warnOnce(_ msg: String) {
        guard !warned.contains(msg) else { return }
        warned.insert(msg)
        fputs("[swift-render] WARN: \(msg)\n", stderr)
    }
}

// MARK: - Environment maps

/// Equirectangular environment images: a procedural float-HDR studio, or a file.
@MainActor
enum EnvironmentMaps {
    private static var studioCache: [Double: CGImage] = [:]
    private static var fileCache: [String: CGImage] = [:]

    static func purge() { studioCache = [:]; fileCache = [:] }

    static func studio(rotation: Double) -> CGImage? {
        if let hit = studioCache[rotation] { return hit }
        let img = makeStudio(width: 1024, height: 512, rotation: rotation)
        studioCache[rotation] = img
        return img
    }

    static func file(_ path: String, rotation: Double) -> CGImage? {
        guard let url = AssetPaths.resolve(path) else {
            fputs("[swift-render] WARN: environment not found: \(path)\n", stderr)
            return nil
        }
        let key = url.path + "|" + FileStamp.of(url.path) + "|\(rotation)"
        if let hit = fileCache[key] { return hit }
        // ImageIO decodes .hdr and .exr to float CGImages, keeping the highlights above 1.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        else {
            fputs("[swift-render] WARN: environment unreadable: \(path)\n", stderr)
            return nil
        }
        let out = rotation == 0 ? img : rotate(img, degrees: rotation) ?? img
        fileCache[key] = out
        return out
    }

    /// Spin an equirect about Y: a horizontal wrap-around shift.
    private static func rotate(_ img: CGImage, degrees: Double) -> CGImage? {
        let w = img.width, h = img.height
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var shift = (degrees / 360).truncatingRemainder(dividingBy: 1)
        if shift < 0 { shift += 1 }
        let dx = CGFloat(shift) * CGFloat(w)
        ctx.draw(img, in: CGRect(x: dx, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.draw(img, in: CGRect(x: dx - CGFloat(w), y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// A dark photo studio as linear float HDR: graded walls, a large overhead soft box,
    /// two tall strip lights left and right, a smaller front key and a faint floor bounce.
    static func makeStudio(width w: Int, height h: Int, rotation: Double) -> CGImage? {
        var px = [Float](repeating: 0, count: w * h * 4)
        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
        }
        // A soft-edged rectangle in (longitude, latitude) degrees.
        func box(_ lon: Double, _ lat: Double, cLon: Double, cLat: Double, wLon: Double, hLat: Double, soft: Double) -> Double {
            var d = lon - cLon
            d = (d + 540).truncatingRemainder(dividingBy: 360) - 180
            let x = 1 - smooth(wLon / 2 - soft, wLon / 2 + soft, abs(d))
            let y = 1 - smooth(hLat / 2 - soft, hLat / 2 + soft, abs(lat - cLat))
            return x * y
        }
        for j in 0..<h {
            let lat = 90 - (Double(j) + 0.5) / Double(h) * 180          // +90 top … −90 bottom
            for i in 0..<w {
                let lon = (Double(i) + 0.5) / Double(w) * 360 - 180 + rotation
                // Walls: near-black floor, a slow lift toward a dim ceiling.
                let up = max(0, sin(lat * .pi / 180))
                let down = max(0, -sin(lat * .pi / 180))
                var r = 0.018 + 0.05 * up - 0.012 * down
                var g = r, b = r * 1.04
                // Overhead soft box (the big top light every product shot has).
                let top = smooth(48, 70, lat) * 2.2
                // Tall strip boxes left and right, slightly behind the subject (rim light on edges).
                let stripL = box(lon, lat, cLon: -115, cLat: 12, wLon: 12, hLat: 70, soft: 4) * 3.2
                let stripR = box(lon, lat, cLon: 115, cLat: 12, wLon: 12, hLat: 70, soft: 4) * 3.2
                // A front-left key panel and a softer front-right fill card.
                let key = box(lon, lat, cLon: -35, cLat: 25, wLon: 40, hLat: 30, soft: 8) * 2.4
                let fill = box(lon, lat, cLon: 40, cLat: 5, wLon: 50, hLat: 30, soft: 14) * 0.45
                // Warm floor bounce near the horizon.
                let bounce = smooth(-30, -2, lat) * (1 - smooth(-2, 6, lat)) * 0.06
                let light = top + stripL + stripR + key + fill
                r += light + bounce * 1.1
                g += light + bounce * 0.95
                b += light * 1.02 + bounce * 0.8
                let o = (j * w + i) * 4
                px[o] = Float(r); px[o + 1] = Float(g); px[o + 2] = Float(b); px[o + 3] = 1
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.floatComponents.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
